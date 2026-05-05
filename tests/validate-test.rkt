#lang racket/base

;; Unit tests for nisp/validate. Uses a synthetic schema-table so no
;; `nix eval` or external state is needed.

(require rackunit
         (only-in nisp/validate
                  path-ref-path
                  walk-syntax
                  extract-from-form
                  infer-value-type
                  check-type
                  find-similar-strs
                  levenshtein
                  describe-val))

(define (parse src)
  (define port (open-input-string src))
  (port-count-lines! port)
  (read-syntax 'test port))

(define (collect-paths src)
  (define paths '())
  (walk-syntax (parse src)
    (λ (s _) (for ([pr (in-list (extract-from-form s))])
               (set! paths (cons (path-ref-path pr) paths)))))
  (reverse paths))

;; ---------- AST walker ----------

(test-case "extract paths from set/enable forms"
  (check-equal? (collect-paths "(set 'services.openssh.enable #t)")
                '("services.openssh.enable"))
  (check-equal? (collect-paths "(enable 'a.b 'c.d)")
                '("a.b.enable" "c.d.enable")))

(test-case "skip non-set/enable forms"
  (check-equal? (collect-paths "(let-in ([x 1]) x)") '())
  (check-equal? (collect-paths "(if-then #t 1 2)") '()))

(test-case "walk descends into nested forms"
  (check-equal? (collect-paths "(att (a (set 'foo.bar #t)))")
                '("foo.bar")))

;; ---------- value-type inference ----------

(define (infer src) (infer-value-type (parse src)))

(test-case "literal values"
  (check-equal? (car (infer "#t")) 'bool)
  (check-equal? (car (infer "42")) 'int)
  (check-equal? (infer "\"hi\"") '(str-lit "hi"))
  (check-equal? (car (infer "null")) 'null))

(test-case "compound values"
  (check-equal? (car (infer "(s \"hello\" name)")) 'str)
  (check-equal? (car (infer "(p \"./foo\")")) 'path)
  (check-equal? (car (infer "(with-pkgs vim git)")) 'packages)
  (check-equal? (car (infer "(att (a 1) (b 2))")) 'attrset)
  (check-equal? (car (infer "(lst 1 2 3)")) 'list))

(test-case "mk* unwrap"
  (check-equal? (car (infer "(mkdefault 5)")) 'int)
  (check-equal? (car (infer "(mkforce \"x\")")) 'str-lit)
  (check-equal? (car (infer "(mkif cond 42)")) 'int))

(test-case "unknown for things we can't classify"
  (check-equal? (infer "x") '(unknown))
  (check-equal? (infer "(call f x)") '(unknown)))

;; ---------- check-type ----------

(define (entry t #:inner [inner #f] #:enum [enum #f])
  (define h (hasheq 't t))
  (let* ([h (if inner (hash-set h 'inner inner) h)]
         [h (if enum (hash-set h 'enum enum) h)])
    h))

(test-case "bool"
  (check-equal? (check-type (entry "bool") '(bool)) 'ok)
  (define m (check-type (entry "bool") '(int)))
  (check-pred pair? m)
  (check-equal? (car m) 'mismatch))

(test-case "str / int / path"
  (check-equal? (check-type (entry "str") '(str-lit "x")) 'ok)
  (check-equal? (check-type (entry "int") '(int)) 'ok)
  (check-equal? (check-type (entry "path") '(path)) 'ok)
  (check-equal? (check-type (entry "path") '(str-lit "./foo")) 'ok))

(test-case "nullOr inner"
  (define t (entry "nullOr" #:inner (entry "int")))
  (check-equal? (check-type t '(null)) 'ok)
  (check-equal? (check-type t '(int)) 'ok)
  (define m (check-type t '(str-lit "x")))
  (check-equal? (car m) 'mismatch))

(test-case "listOf inner element check"
  (define t (entry "listOf" #:inner (entry "int")))
  (check-equal? (check-type t (list 'list (list '(int) '(int)))) 'ok)
  (define m (check-type t (list 'list (list '(int) '(str-lit "x")))))
  (check-equal? (car m) 'mismatch))

(test-case "attrsOf leaf — recurse on values"
  (define t (entry "attrsOf" #:inner (entry "str")))
  (check-equal? (check-type t (list 'attrset (list '(str-lit "a") '(str-lit "b")))) 'ok)
  (define m (check-type t (list 'attrset (list '(str-lit "a") '(attrset '())))))
  (check-equal? (car m) 'mismatch))

(test-case "enum match + did-you-mean"
  (define t (entry "enum" #:enum '("a" "b" "auto")))
  (check-equal? (check-type t '(str-lit "auto")) 'ok)
  (define m (check-type t '(str-lit "atuo")))
  (check-equal? (car m) 'mismatch)
  (check-not-false (regexp-match? #rx"did you mean \"auto\"" (cadr m))))

(test-case "permissive types accept anything"
  (check-equal? (check-type (entry "submodule") '(int)) 'ok)
  (check-equal? (check-type (entry "package") '(unknown)) 'ok))

(test-case "unknown value-tag returns unknown (don't report)"
  (check-equal? (check-type (entry "bool") '(unknown)) 'unknown))

;; ---------- did-you-mean ----------

(test-case "levenshtein distance"
  (check-equal? (levenshtein "auto" "atuo") 2)
  (check-equal? (levenshtein "" "abc") 3)
  (check-equal? (levenshtein "same" "same") 0))

(test-case "find-similar-strs ranks by edit distance"
  (define cands '("services.openssh.enable" "services.openssh.settings"
                  "services.something.else"))
  (define hits (find-similar-strs "services.opensh.enable" cands))
  (check-not-false (member "services.openssh.enable" hits)))
