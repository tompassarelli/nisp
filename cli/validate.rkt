#lang racket/base

;; nisp validate — schema-driven validation of nisp .rkt sources.
;;
;; Thin orchestration over nisp/validate (path/type primitives) and
;; nisp/validate-cache (schema loading + lazy submodule expansion).

(require racket/file
         racket/list
         racket/string
         racket/port
         racket/path
         racket/system
         racket/cmdline
         (only-in nisp/validate
                  path-ref-path path-ref-stx path-ref-val-stx
                  walk-syntax extract-from-form
                  infer-value-type check-type
                  find-similar-strs levenshtein)
         (only-in nisp/validate-cache
                  cache-config cache-config-cache-dir
                  make-schema-state schema-state-table
                  load-schema! discover-and-expand!
                  schema-lookup schema-lookup/wildcard
                  namespace-known? in-submodule?
                  has-interpolation?
                  MODULE-STRUCTURAL-KEYS))

(provide main)

(define (sh-out . args)
  (define o (open-output-string))
  (parameterize ([current-output-port o]) (apply system* args))
  (string-trim (get-output-string o)))

(define (count-char c s)
  (for/sum ([ch (in-string s)] #:when (char=? ch c)) 1))

(define (main)
  (define TARGET (make-parameter #f))
  (define CACHE-DIR (make-parameter #f))
  (define FLAKE (make-parameter #f))
  (define HM-ROOTS-RAW (make-parameter #f))
  (define AUTO-FIX? (make-parameter #f))

  (define files-arg
    (command-line
     #:program "nisp validate"
     #:once-each
     [("--target") t "nix attr-path for submodule expansion" (TARGET t)]
     [("--cache-dir") d "directory holding schema.json + schema-submodules.json" (CACHE-DIR d)]
     [("--flake") f "flake root for `nix eval`" (FLAKE f)]
     [("--hm-roots") r "comma-separated path-prefix allowlist" (HM-ROOTS-RAW r)]
     [("--no-hm") "shorthand for --hm-roots \"\"" (HM-ROOTS-RAW "")]
     [("--auto-fix") "apply unambiguous did-you-mean corrections (single suggestion at edit distance ≤ 2)"
      (AUTO-FIX? #t)]
     #:args files files))

  (define FLAKE-ROOT
    (let ([explicit (FLAKE)])
      (cond
        [explicit (path->complete-path explicit)]
        [else
         (define git (sh-out (find-executable-path "git") "rev-parse" "--show-toplevel"))
         (cond
           [(non-empty-string? git) (string->path git)]
           [else (path->complete-path (find-system-path 'orig-dir))])])))

  (define HM-CONTEXT-ROOTS
    (let ([raw (HM-ROOTS-RAW)])
      (cond
        [(not raw) '()]
        [(equal? raw "") '()]
        [else (string-split raw ",")])))

  (define HOST
    (or (getenv "FIRN_HOST")
        (let ([h (sh-out (find-executable-path "hostname"))])
          (if (non-empty-string? h) h "default"))))

  (define EXPAND-TARGET
    (or (TARGET) (string-append "nixosConfigurations." HOST ".options")))

  (define CFG
    (cache-config FLAKE-ROOT
                  (cond [(CACHE-DIR) (path->complete-path (CACHE-DIR))]
                        [else (build-path FLAKE-ROOT ".nisp-cache")])
                  EXPAND-TARGET
                  HM-CONTEXT-ROOTS))

  (define SCHEMA-PATH (build-path (cache-config-cache-dir CFG) "schema.json"))

  (unless (file-exists? SCHEMA-PATH)
    (eprintf "nisp validate: schema not found at ~a\n" SCHEMA-PATH)
    (eprintf "  run `nisp extract-schema` first.\n")
    (exit 2))

  (define STATE (make-schema-state CFG))
  (load-schema! STATE)

  (define (find-similar path [n 3])
    (find-similar-strs path (hash-keys (schema-state-table STATE)) n))

  (define (validate-path p)
    (cond
      [(has-interpolation? p) 'skip]
      [(member p MODULE-STRUCTURAL-KEYS) 'structural]
      [(schema-lookup STATE p) 'ok]
      [(schema-lookup/wildcard STATE p) 'ok]
      [(namespace-known? STATE p) 'namespace]
      [(in-submodule? STATE p) 'submodule]
      [(let ([root (car (string-split p "."))]) (member root HM-CONTEXT-ROOTS))
       'hm-context]
      [else 'unknown]))

  (define total-errors 0)
  (define auto-fixes-applied 0)

  (define (try-auto-fix! src-file p sims)
    (cond
      [(or (not (AUTO-FIX?)) (null? sims)) #f]
      [else
       (define ranked
         (sort (map (λ (s) (cons (levenshtein p s) s)) sims) < #:key car))
       (define best (car ranked))
       (define best-dist (car best))
       (define best-sug (cdr best))
       (cond
         [(> best-dist 2) #f]
         [(and (pair? (cdr ranked))
               (or (= (caadr ranked) best-dist)
                   (< (caadr ranked) (+ best-dist 2))))
          #f]
         [else
          (define text (file->string src-file))
          (define old-re
            (regexp (string-append "(?<![a-zA-Z0-9_-])" (regexp-quote p) "(?=$|[^a-zA-Z0-9_-])")))
          (define replaced (regexp-replace* old-re text best-sug))
          (cond
            [(equal? replaced text) #f]
            [else
             (display-to-file replaced src-file #:exists 'replace)
             (set! auto-fixes-applied (+ auto-fixes-applied 1))
             #t])])]))

  (define (report-unknown-path src stx p)
    (define line (or (syntax-line stx) "?"))
    (define col  (or (syntax-column stx) "?"))
    (define sims (find-similar p))
    (cond
      [(try-auto-fix! src p sims)
       (eprintf "~a:~a:~a: auto-fixed ~a → ~a\n" src line col p (car sims))]
      [else
       (set! total-errors (+ total-errors 1))
       (eprintf "~a:~a:~a: unknown option ~a\n" src line col p)
       (when (not (null? sims))
         (eprintf "  did you mean: ~a?\n" (string-join sims ", " #:before-last " or ")))]))

  (define (report-type-mismatch src val-stx p msg)
    (set! total-errors (+ total-errors 1))
    (define line (or (and val-stx (syntax-line val-stx)) "?"))
    (define col  (or (and val-stx (syntax-column val-stx)) "?"))
    (eprintf "~a:~a:~a: type mismatch at ~a: ~a\n" src line col p msg))

  (define (validate-file f)
    (define raw (call-with-input-file f port->string))
    (define-values (lang-prefix rest)
      (let ([m (regexp-match-positions #rx"^#lang [^\n]*\n" raw)])
        (cond [m (values (substring raw 0 (cdr (car m)))
                         (substring raw (cdr (car m))))]
              [else (values "" raw)])))
    (define padded (string-append (make-string (count-char #\newline lang-prefix) #\newline)
                                  rest))
    (define port (open-input-string padded))
    (port-count-lines! port)
    (define src (path->string f))
    (with-handlers ([exn:fail:read?
                     (λ (e)
                       (eprintf "~a: parse error: ~a\n" src (exn-message e))
                       (set! total-errors (+ total-errors 1)))])
      (let loop ()
        (define stx (read-syntax src port))
        (unless (eof-object? stx)
          (walk-syntax stx
            (λ (s in-hm?)
              (unless in-hm?
                (for ([pr (in-list (extract-from-form s))])
                  (define p (path-ref-path pr))
                  (define stx-loc (path-ref-stx pr))
                  (define val-stx (path-ref-val-stx pr))
                  (case (validate-path p)
                    [(unknown) (report-unknown-path src stx-loc p)]
                    [(ok)
                     (when val-stx
                       (define entry (schema-lookup/wildcard STATE p))
                       (when entry
                         (define vt (infer-value-type val-stx))
                         (define result (check-type entry vt))
                         (when (and (pair? result) (eq? (car result) 'mismatch))
                           (report-type-mismatch src val-stx p (cadr result)))))]
                    [else (void)])))))
          (loop)))))

  (define files
    (cond
      [(null? files-arg)
       (sort
        (for/list ([f (in-directory FLAKE-ROOT)]
                   #:when (let ([ps (path->string f)])
                            (and (regexp-match? #rx"\\.rkt$" ps)
                                 (not (regexp-match? #rx"/scripts/" ps))
                                 (not (regexp-match? #rx"/tests/" ps))
                                 (not (regexp-match? #rx"/\\.nisp-cache/" ps))
                                 (not (regexp-match? #rx"/\\.firn-build/" ps))
                                 (not (regexp-match? #rx"/\\.direnv/" ps))
                                 (not (regexp-match? #rx"/\\.git/" ps))
                                 (not (regexp-match? #rx"/result" ps))
                                 (with-handlers ([exn:fail? (λ (_) #f)])
                                   (regexp-match?
                                    #rx"^#lang nisp"
                                    (call-with-input-file f
                                      (λ (p) (read-line p))))))))
          f)
        string<? #:key path->string)]
      [else (map string->path files-arg)]))

  (printf "nisp validate: discovering submodule prefixes...\n")
  (discover-and-expand! STATE files (current-output-port))

  (printf "nisp validate: checking ~a file(s) against ~a option paths...\n"
          (length files) (hash-count (schema-state-table STATE)))

  (for ([f (in-list files)])
    (validate-file f))

  (when (and (AUTO-FIX?) (positive? auto-fixes-applied))
    (printf "nisp validate: applied ~a auto-fix(es). Re-run to verify.\n" auto-fixes-applied))

  (if (zero? total-errors)
      (printf "nisp validate: clean — no unknown options.\n")
      (eprintf "\n~a error(s).\n" total-errors))

  (exit (if (zero? total-errors) 0 1)))
