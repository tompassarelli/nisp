#lang racket/base

;; nisp/validate-packages — package name caching and validation.
;;
;; Extracts package references from nisp forms (with-pkgs, lst pkgs.X)
;; and validates them against a cached set of known nixpkgs attr names.

(require racket/file
         racket/list
         racket/string
         racket/path
         json
         (only-in nisp/validate find-similar-strs))

(provide
 (struct-out pkg-ref)
 (struct-out pkg-cache-state)
 make-pkg-cache-state
 load-package-cache!
 pkg-cache-loaded?
 validate-pkg-ref
 extract-pkg-refs-from-form
 PKG-CACHE-FILE)

(define PKG-CACHE-FILE "packages.json")

;; A package reference extracted from source.
;; name: the leaf attr name to validate
;; set: "pkgs", "unstable", or "master"
;; src-stx: syntax object for error reporting
(struct pkg-ref (name set src-stx) #:transparent)

;; State holding loaded package sets.
(struct pkg-cache-state (pkgs unstable master overlays loaded?)
  #:mutable #:transparent)

(define (make-pkg-cache-state)
  (pkg-cache-state '() '() '() '() #f))

(define (load-package-cache! state cache-dir)
  (define p (build-path cache-dir PKG-CACHE-FILE))
  (when (file-exists? p)
    (with-handlers ([exn:fail? void])
      (define data (call-with-input-file p read-json))
      (set-pkg-cache-state-pkgs! state (hash-ref data 'pkgs '()))
      (set-pkg-cache-state-unstable! state (hash-ref data 'unstable '()))
      (set-pkg-cache-state-master! state (hash-ref data 'master '()))
      (define sets (hash-ref data 'sets #f))
      (when sets
        (set-pkg-cache-state-pkgs! state (hash-ref sets 'pkgs '()))
        (set-pkg-cache-state-unstable! state (hash-ref sets 'unstable '()))
        (set-pkg-cache-state-master! state (hash-ref sets 'master '())))
      (set-pkg-cache-state-overlays! state (hash-ref data 'overlays '()))
      (set-pkg-cache-state-loaded?! state #t))))

(define (pkg-cache-loaded? state)
  (pkg-cache-state-loaded? state))

(define (get-set state set-name)
  (case set-name
    [("pkgs") (pkg-cache-state-pkgs state)]
    [("unstable") (pkg-cache-state-unstable state)]
    [("master") (pkg-cache-state-master state)]
    [else '()]))

(define (validate-pkg-ref state ref)
  (define name (pkg-ref-name ref))
  (define set-name (pkg-ref-set ref))
  (define names (get-set state set-name))
  (cond
    [(member name (pkg-cache-state-overlays state)) 'overlay]
    [(member name names) 'ok]
    [else
     (define suggestions (find-similar-strs name names))
     (list 'unknown suggestions)]))

;; Parse a dotted identifier into (values leaf-name set-name).
;; Rules:
;;   "unstable.foo"        → foo in "unstable"
;;   "master.bar"          → bar in "master"
;;   "wineWowPackages.x"   → wineWowPackages in "pkgs" (top-level validation)
;;   "vim"                 → vim in "pkgs"
(define (parse-dotted-ident s)
  (define parts (string-split s "." #:trim? #f))
  (cond
    [(null? parts) (values s "pkgs")]
    [(and (>= (length parts) 2)
          (equal? (car parts) "unstable"))
     (values (string-join (cdr parts) ".") "unstable")]
    [(and (>= (length parts) 2)
          (equal? (car parts) "master"))
     (values (string-join (cdr parts) ".") "master")]
    [(>= (length parts) 2)
     ;; Nested attr like wineWowPackages.unstable — validate first segment at top level
     (values (car parts) "pkgs")]
    [else (values s "pkgs")]))

;; Parse a pkgs.X identifier from an `lst` form.
;; "pkgs.unstable.foo" → foo in "unstable"
;; "pkgs.master.bar"   → bar in "master"
;; "pkgs.vim"          → vim in "pkgs"
;; "pkgs.wine.x"       → wine in "pkgs"
(define (parse-pkgs-ident s)
  (define without-prefix (substring s 5)) ; strip "pkgs."
  (parse-dotted-ident without-prefix))

(define (extract-pkg-refs-from-form stx)
  (define lst (and (syntax? stx) (syntax->list stx)))
  (cond
    [(or (not lst) (null? lst)) '()]
    [else
     (define head (and (identifier? (car lst))
                       (syntax->datum (car lst))))
     (define args (cdr lst))
     (cond
       [(eq? head 'with-pkgs)
        (filter-map
         (λ (arg)
           (define dat (and (syntax? arg) (syntax->datum arg)))
           (cond
             [(symbol? dat)
              (define s (symbol->string dat))
              (define-values (name set-name) (parse-dotted-ident s))
              (pkg-ref name set-name arg)]
             [else #f]))
         args)]
       [(eq? head 'lst)
        (filter-map
         (λ (arg)
           (define dat (and (syntax? arg) (syntax->datum arg)))
           (cond
             [(and (symbol? dat)
                   (let ([s (symbol->string dat)])
                     (string-prefix? s "pkgs.")))
              (define s (symbol->string dat))
              (define-values (name set-name) (parse-pkgs-ident s))
              (pkg-ref name set-name arg)]
             [else #f]))
         args)]
       [else '()])]))
