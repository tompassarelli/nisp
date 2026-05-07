#lang racket/base

;; nisp schema — query the cached options schema.
;;
;; Three modes:
;;   nisp schema <path>              show type/default/desc for an exact option
;;   nisp schema --children <prefix> list all options under a path prefix
;;   nisp schema --search <query>    fuzzy match across all option paths
;;
;; All modes accept `--json` for machine-readable output.

(require racket/cmdline
         racket/list
         racket/string
         racket/file
         racket/path
         json
         (only-in nisp/validate find-similar-strs)
         (only-in nisp/validate-cache
                  cache-config make-schema-state
                  schema-state-table load-schema!))

(provide main)

(define (find-flake-root)
  (define start (path->complete-path (find-system-path 'orig-dir)))
  (let loop ([d (simple-form-path start)])
    (cond
      [(file-exists? (build-path d "flake.rkt")) d]
      [(file-exists? (build-path d "flake.nix")) d]
      [else
       (define-values (parent _name _isdir) (split-path d))
       (cond
         [(or (not parent) (eq? parent 'relative)) start]
         [else (loop parent)])])))

(define (describe-type t inner)
  (cond
    [(member t '("listOf" "nullOr" "attrsOf" "lazyAttrsOf"))
     (define inner-t (and inner (hash-ref inner 't "?")))
     (define inner-inner (and inner (hash-ref inner 'inner #f)))
     (format "~a (~a)" t (describe-type inner-t inner-inner))]
    [(string? t) t]
    [else "?"]))

(define (entry->plain entry)
  (define t (hash-ref entry 't "?"))
  (define inner (hash-ref entry 'inner #f))
  (define enum (hash-ref entry 'enum #f))
  (define desc-parts (list (format "type:    ~a" (describe-type t inner))))
  (cond
    [enum
     (define enum-strs (map (λ (v) (format "~s" v)) enum))
     (set! desc-parts (append desc-parts
                              (list (format "enum:    ~a" (string-join enum-strs ", ")))))])
  (string-join desc-parts "\n"))

(define (main)
  (define ROOT (find-flake-root))
  (define CACHE-DIR (make-parameter (build-path ROOT ".nisp-cache")))
  (define MODE (make-parameter 'lookup))
  (define JSON? (make-parameter #f))

  (define args
    (command-line
     #:program "nisp schema"
     #:once-each
     [("--cache-dir") d "directory holding schema.json + schema-submodules.json"
      (CACHE-DIR (path->complete-path d))]
     [("--json") "machine-readable JSON output"
      (JSON? #t)]
     #:once-any
     [("--children") "list options under a prefix instead of looking up exact path"
      (MODE 'children)]
     [("--search") "fuzzy-match query across all option paths"
      (MODE 'search)]
     #:args args
     args))

  (when (null? args)
    (eprintf "usage: nisp schema [--children|--search] [--json] <query>\n")
    (exit 2))

  (define query (car args))

  (define SCHEMA-PATH (build-path (CACHE-DIR) "schema.json"))

  (unless (file-exists? SCHEMA-PATH)
    (eprintf "nisp schema: ~a not found. Run `nisp extract-schema`.\n" SCHEMA-PATH)
    (exit 2))

  (define STATE
    (let ([cfg (cache-config (or (path-only SCHEMA-PATH) (current-directory))
                             (CACHE-DIR)
                             "nixosConfigurations.default.options"
                             '())])
      (define s (make-schema-state cfg))
      (load-schema! s)
      s))

  (define schema-table (schema-state-table STATE))

  (define (emit-json result) (write-json result) (newline))

  (define (emit-text-lookup path entry)
    (cond
      [(not entry)
       (define sims (find-similar-strs path (hash-keys schema-table) 5))
       (eprintf "no exact match for ~a\n" path)
       (when (not (null? sims))
         (eprintf "did you mean:\n")
         (for ([s (in-list sims)]) (eprintf "  ~a\n" s)))
       (exit 1)]
      [else
       (printf "path:    ~a\n" path)
       (printf "~a\n" (entry->plain entry))]))

  (define (emit-text-children prefix matches)
    (cond
      [(null? matches)
       (eprintf "no options found under ~a\n" prefix) (exit 1)]
      [else
       (printf "options under ~a:\n" prefix)
       (for ([e (in-list matches)])
         (define p (hash-ref e 'p))
         (define t (describe-type (hash-ref e 't "?") (hash-ref e 'inner #f)))
         (printf "  ~a : ~a\n" p t))]))

  (define (emit-text-search query matches)
    (cond
      [(null? matches)
       (eprintf "no options match ~a\n" query) (exit 1)]
      [else
       (printf "options matching ~a:\n" query)
       (for ([e (in-list (take matches (min 20 (length matches))))])
         (define p (hash-ref e 'p))
         (define t (describe-type (hash-ref e 't "?") (hash-ref e 'inner #f)))
         (printf "  ~a : ~a\n" p t))
       (when (> (length matches) 20)
         (printf "  ... ~a more\n" (- (length matches) 20)))]))

  (define (do-lookup path)
    (define entry (hash-ref schema-table path #f))
    (cond
      [(JSON?)
       (cond
         [entry (emit-json entry)]
         [else (emit-json (hasheq 'p path 'found #f
                                  'similar (find-similar-strs path (hash-keys schema-table) 5)))])]
      [else (emit-text-lookup path entry)]))

  (define (do-children prefix)
    (define matches
      (sort
       (for/list ([(k v) (in-hash schema-table)]
                  #:when (string-prefix? k (string-append prefix ".")))
         v)
       string<? #:key (λ (e) (hash-ref e 'p))))
    (cond
      [(JSON?) (emit-json matches)]
      [else (emit-text-children prefix matches)]))

  (define (do-search query)
    (define substr-matches
      (for/list ([(k v) (in-hash schema-table)]
                 #:when (regexp-match? (regexp-quote query) k))
        v))
    (define matches
      (cond
        [(not (null? substr-matches))
         (sort substr-matches string<? #:key (λ (e) (hash-ref e 'p)))]
        [else
         (define sims (find-similar-strs query (hash-keys schema-table) 20))
         (filter-map (λ (k) (hash-ref schema-table k #f)) sims)]))
    (cond
      [(JSON?) (emit-json matches)]
      [else (emit-text-search query matches)]))

  (case (MODE)
    [(lookup)   (do-lookup query)]
    [(children) (do-children query)]
    [(search)   (do-search query)]))
