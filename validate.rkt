#lang racket/base

;; nisp/validate — schema-driven static validation primitives for nisp ASTs.
;;
;; This module provides the *generic* parts of source-aware validation:
;; walk a parsed nisp source, extract every (set 'PATH val) / (enable 'PATH)
;; reference, infer the value's static shape, and check it against a
;; schema entry's expected type. Did-you-mean suggestions are Levenshtein
;; based.
;;
;; What this module does NOT know: where schemas come from (NixOS options
;; tree? home-manager? something else?), how paths are cached, how to
;; expand submodules. Those are *consumer concerns* — provide a populated
;; schema-table and the validation runs against it.
;;
;; Schema entry shape:
;;   { 't  : "bool" | "str" | "int" | "listOf" | "nullOr" | "enum" | ... ;
;;     'inner : (recursive entry) ;     ; for parameterized containers
;;     'enum  : (list of strings) }     ; for enum types
;;
;; Typical use:
;;
;;   (require nisp/validate)
;;
;;   (define schema-table (load-your-schema))
;;
;;   (for ([file (in-list source-files)])
;;     (define stx (read-syntax-of file))
;;     (walk-syntax stx
;;       (λ (s in-hm?)
;;         (for ([pr (in-list (extract-from-form s))])
;;           (define p (path-ref-path pr))
;;           (define val-stx (path-ref-val-stx pr))
;;           (define entry (hash-ref schema-table p #f))
;;           (cond
;;             [(not entry)
;;              (report-unknown p (find-similar-strs p (hash-keys schema-table)))]
;;             [val-stx
;;              (define val-type (infer-value-type val-stx))
;;              (define result (check-type entry val-type))
;;              (when (and (pair? result) (eq? (car result) 'mismatch))
;;                (report-type-mismatch p val-stx (cadr result)))])))))

(require racket/list
         racket/string)

(provide
 ;; AST walking
 (struct-out path-ref)
 walk-syntax
 extract-from-form
 extract-quoted-sym

 ;; Value-type inference
 infer-value-type
 attrset-val-types

 ;; Type matching
 check-type

 ;; Did-you-mean
 levenshtein
 find-similar-strs)

;; Internal helpers (not exported; available within the library):
;; describe-val, STR-TYPES, INT-TYPES, PERMISSIVE-TYPES, str-type?,
;; int-type?, path-type?, bool-type?, float-type?, permissive-type?
;; — these were exposed for hypothetical "third-party validator builders"
;; that never materialized. Removed from public API; internal callers in
;; check-type still use them. If you need them as escape hatches, file
;; an issue with the use case.

;; ============================================================================
;; AST walking
;; ============================================================================

(struct path-ref (path stx val-stx) #:transparent)

(define (extract-quoted-sym stx)
  (define lst (syntax->list stx))
  (and lst
       (= (length lst) 2)
       (let ([head (and (identifier? (car lst))
                        (syntax->datum (car lst)))])
         (and (eq? head 'quote)
              (let ([inner (syntax->datum (cadr lst))])
                (and (symbol? inner) (symbol->string inner)))))))

;; Extract path-refs from a single form. Currently recognises `(set 'PATH val)`
;; and `(enable 'P1 'P2 ...)`. Other forms return '().
(define (extract-from-form stx)
  (define lst (syntax->list stx))
  (cond
    [(or (not lst) (null? lst)) '()]
    [else
     (define head (and (identifier? (car lst))
                       (syntax->datum (car lst))))
     (define rest (cdr lst))
     (cond
       [(and (eq? head 'set) (not (null? rest)))
        (define maybe-path (extract-quoted-sym (car rest)))
        (define val-stx (and (not (null? (cdr rest))) (cadr rest)))
        (if maybe-path
            (list (path-ref maybe-path (car rest) val-stx))
            '())]
       [(eq? head 'enable)
        (filter-map
         (λ (arg)
           (define p (extract-quoted-sym arg))
           (and p (path-ref (string-append p ".enable") arg #f)))
         rest)]
       [else '()])]))

;; Walk a syntax tree with optional HM-context tracking. The visitor
;; receives (stx in-hm?) — `in-hm?` is #t when inside a `home-of` /
;; `home-of-bare` / `hm` / `hm-bare` / `hm-module` body. Useful when
;; you want to skip option-validation inside HM submodules whose
;; schema you don't have.
(define HM-FORMS '(home-of home-of-bare hm hm-bare hm-module))

(define (walk-syntax stx visit [in-hm? #f])
  (visit stx in-hm?)
  (define lst (syntax->list stx))
  (when lst
    (define head (and (pair? lst) (identifier? (car lst))
                      (syntax->datum (car lst))))
    (define child-hm? (or in-hm? (and (member head HM-FORMS) #t)))
    (for-each (λ (s) (walk-syntax s visit child-hm?)) lst)))

;; ============================================================================
;; Value-type inference
;; ============================================================================
;;
;; Walk a value-side syntax object and classify what kind of Nix value it
;; produces. Returns one of:
;;
;;   '(bool)               #t / #f
;;   '(str)                (s ...) interpolated string
;;   `(str-lit ,value)     plain string literal — value preserved for enum check
;;   '(int)                integer literal
;;   '(float)              floating-point literal
;;   '(null)               null literal
;;   '(path)               (p ...) form
;;   '(packages)           (with-pkgs ...) — list of package
;;   `(list ,types)        (lst ...) — types is list of inferred element types
;;   `(attrset ,vals)      (att ...) — vals is list of inferred value types
;;   '(unknown)            anything else (let-bound names, calls, mk*, etc.)

(define (infer-value-type stx)
  (define dat (and (syntax? stx) (syntax->datum stx)))
  (cond
    [(boolean? dat) '(bool)]
    [(exact-integer? dat) '(int)]
    [(real? dat) '(float)]
    [(string? dat) (list 'str-lit dat)]
    [(eq? dat 'null) '(null)]
    [(pair? dat)
     (define lst (syntax->list stx))
     (cond
       [(or (not lst) (null? lst)) '(unknown)]
       [else
        (define head-stx (car lst))
        (define head (and (identifier? head-stx) (syntax->datum head-stx)))
        (define args (cdr lst))
        (case head
          [(s ms) '(str)]
          [(p) '(path)]
          [(with-pkgs) '(packages)]
          [(lst) (list 'list (map infer-value-type args))]
          [(att)
           (define val-types
             (filter-map
              (λ (entry)
                (define elst (and (syntax? entry) (syntax->list entry)))
                (and elst (= (length elst) 2)
                     (infer-value-type (cadr elst))))
              args))
           (list 'attrset val-types)]
          [(mkdefault mkforce)
           (if (and (pair? args) (not (null? args)))
               (infer-value-type (car args))
               '(unknown))]
          [(mkif)
           (if (and (pair? args) (not (null? (cdr args))))
               (infer-value-type (cadr args))
               '(unknown))]
          [else '(unknown)])])]
    [else '(unknown)]))

(define (attrset-val-types val-type)
  (cond
    [(and (pair? val-type) (eq? (car val-type) 'attrset)
          (pair? (cdr val-type)))
     (cadr val-type)]
    [else '()]))

(define (describe-val val-type)
  (case (car val-type)
    [(bool) "bool"]
    [(int) "int"]
    [(float) "float"]
    [(str str-lit) "string"]
    [(null) "null"]
    [(path) "path"]
    [(packages) "list of packages"]
    [(list) "list"]
    [(attrset) "attrset"]
    [else "unknown"]))

;; ============================================================================
;; Type-name predicates
;; ============================================================================

(define STR-TYPES
  '("str" "string" "singleLineStr" "passwdEntry" "separatedString"
    "lines" "commas" "envVar"))

(define INT-TYPES
  '("int" "ints.unsigned" "ints.positive" "ints.between"
    "unsignedInt8" "unsignedInt16" "unsignedInt32" "unsignedInt64"
    "signedInt8" "signedInt16" "signedInt32" "signedInt64"
    "port" "u8" "u16" "u32" "u64" "s8" "s16" "s32" "s64"))

(define PERMISSIVE-TYPES
  ;; Types where we can't statically check meaningfully — accept any value.
  '("submodule" "anything" "unspecified" "raw"
    "either" "oneOf" "coercedTo" "addCheck" "functionTo" "package"
    "deferredModule" "optionType" "loaOf" "uniq" "attrs" "freeformType"))

(define (str-type? t)
  (or (and (member t STR-TYPES) #t)
      (and (string? t) (regexp-match? #rx"^strMatching" t) #t)))

(define (int-type? t)
  (or (and (member t INT-TYPES) #t)
      (and (string? t) (regexp-match? #rx"^ints\\." t) #t)))

(define (path-type? t) (and (member t '("path" "pathInStore")) #t))
(define (bool-type? t) (equal? t "bool"))
(define (float-type? t) (or (equal? t "float") (equal? t "number")))
(define (permissive-type? t) (and (member t PERMISSIVE-TYPES) #t))

;; ============================================================================
;; Type matching
;; ============================================================================
;;
;; Given a schema entry (hash) and an inferred value-type, return one of:
;;   'ok                — types are compatible (or check skipped)
;;   'unknown           — couldn't determine (don't report)
;;   `(mismatch ,msg)   — definite mismatch; msg is a short description
;;
;; Conservative: only flags when CERTAIN.

(define (check-type expected-entry val-type)
  (define t (hash-ref expected-entry 't "?"))
  (define val-tag (car val-type))
  (cond
    [(member t PERMISSIVE-TYPES) 'ok]
    [(equal? t "?") 'ok]
    [(eq? val-tag 'unknown) 'unknown]

    [(bool-type? t)
     (case val-tag
       [(bool) 'ok]
       [else `(mismatch ,(format "expected bool, got ~a" (describe-val val-type)))])]

    [(str-type? t)
     (case val-tag
       [(str str-lit) 'ok]
       [else `(mismatch ,(format "expected ~a, got ~a" t (describe-val val-type)))])]

    [(int-type? t)
     (case val-tag
       [(int) 'ok]
       [else `(mismatch ,(format "expected ~a, got ~a" t (describe-val val-type)))])]

    [(float-type? t)
     (case val-tag
       [(float int) 'ok]
       [else `(mismatch ,(format "expected ~a, got ~a" t (describe-val val-type)))])]

    [(path-type? t)
     (case val-tag
       [(path str str-lit) 'ok]
       [else `(mismatch ,(format "expected path, got ~a" (describe-val val-type)))])]

    [(equal? t "nullOr")
     (cond
       [(eq? val-tag 'null) 'ok]
       [(hash-ref expected-entry 'inner #f)
        => (λ (inner) (check-type inner val-type))]
       [else 'ok])]

    [(member t '("attrsOf" "lazyAttrsOf"))
     (case val-tag
       [(attrset)
        (define inner (hash-ref expected-entry 'inner #f))
        (cond
          [(not inner) 'ok]
          [(member (hash-ref inner 't "?") PERMISSIVE-TYPES) 'ok]
          [else
           (define inner-vals (attrset-val-types val-type))
           (define mismatches
             (filter (λ (r) (and (pair? r) (eq? (car r) 'mismatch)))
                     (map (λ (v) (check-type inner v)) inner-vals)))
           (if (null? mismatches) 'ok (car mismatches))])]
       [else `(mismatch ,(format "expected attrset, got ~a" (describe-val val-type)))])]

    [(equal? t "listOf")
     (case val-tag
       [(packages)
        (define inner (hash-ref expected-entry 'inner #f))
        (define inner-t (and inner (hash-ref inner 't "?")))
        (if (or (not inner-t) (equal? inner-t "package") (member inner-t PERMISSIVE-TYPES))
            'ok
            `(mismatch ,(format "expected listOf ~a, got list of packages" inner-t)))]
       [(list)
        (define inner (hash-ref expected-entry 'inner #f))
        (cond
          [(not inner) 'ok]
          [else
           (define elems (cadr val-type))
           (define mismatches
             (filter (λ (r) (and (pair? r) (eq? (car r) 'mismatch)))
                     (map (λ (e) (check-type inner e)) elems)))
           (if (null? mismatches) 'ok (car mismatches))])]
       [else `(mismatch ,(format "expected list, got ~a" (describe-val val-type)))])]

    [(equal? t "enum")
     (define enum-vals (hash-ref expected-entry 'enum #f))
     (cond
       [(not enum-vals) 'ok]
       [(eq? val-tag 'str-lit)
        (define v (cadr val-type))
        (if (member v enum-vals)
            'ok
            (let ([sims (find-similar-strs v enum-vals)])
              `(mismatch
                ,(format "~s not in enum {~a}~a"
                         v
                         (string-join (map (λ (s) (format "~s" s)) enum-vals) ", ")
                         (if (null? sims)
                             ""
                             (format " — did you mean ~a?"
                                     (string-join (map (λ (s) (format "~s" s)) sims)
                                                  " or ")))))))]
       [(eq? val-tag 'str) 'unknown]
       [else `(mismatch ,(format "expected enum string, got ~a" (describe-val val-type)))])]

    [else 'ok]))

;; ============================================================================
;; Did-you-mean
;; ============================================================================

(define (levenshtein a b)
  (define m (string-length a))
  (define n (string-length b))
  (cond
    [(zero? m) n]
    [(zero? n) m]
    [else
     (define prev (make-vector (+ n 1)))
     (define curr (make-vector (+ n 1)))
     (for ([j (in-range (+ n 1))]) (vector-set! prev j j))
     (for ([i (in-range 1 (+ m 1))])
       (vector-set! curr 0 i)
       (for ([j (in-range 1 (+ n 1))])
         (define cost (if (char=? (string-ref a (- i 1))
                                  (string-ref b (- j 1)))
                          0 1))
         (vector-set! curr j
           (min (+ (vector-ref prev j) 1)
                (+ (vector-ref curr (- j 1)) 1)
                (+ (vector-ref prev (- j 1)) cost))))
       (define tmp prev) (set! prev curr) (set! curr tmp))
     (vector-ref prev n)]))

(define (find-similar-strs target candidates [max-results 3])
  (define max-edits
    (max 2 (min 4 (quotient (string-length target) 3))))
  (define cands
    (for/list ([s (in-list candidates)]
               #:when (<= (levenshtein target s) max-edits))
      (cons (levenshtein target s) s)))
  (define sorted (sort cands < #:key car))
  (map cdr (if (> (length sorted) max-results)
               (take sorted max-results)
               sorted)))
