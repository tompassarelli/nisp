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
                  MODULE-STRUCTURAL-KEYS)
         (only-in nisp/validate-packages
                  pkg-ref pkg-ref-name pkg-ref-set pkg-ref-src-stx
                  make-pkg-cache-state load-package-cache!
                  pkg-cache-loaded? validate-pkg-ref
                  extract-pkg-refs-from-form))

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
  (define NO-PACKAGES? (make-parameter #f))

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
     [("--no-packages") "skip package name validation" (NO-PACKAGES? #t)]
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

  ;; Package validation state
  (define PKG-STATE (make-pkg-cache-state))
  (unless (NO-PACKAGES?)
    (load-package-cache! PKG-STATE (cache-config-cache-dir CFG))
    (unless (pkg-cache-loaded? PKG-STATE)
      (printf "nisp validate: package cache not found, skipping package checks (run `nisp extract-packages` to enable)\n")))

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
  (define pkg-errors 0)
  (define auto-fixes-applied 0)
  (define cross-file-conflicts 0)

  ;; Cross-file conflict detection:
  ;; path → (listof (list file line col val-summary))
  (define cross-file-assignments (make-hash))

  ;; Summarize a value syntax for cross-file comparison.
  ;; Returns a known representation or '<expr> for complex forms.
  (define (summarize-val val-stx)
    (cond
      [(not val-stx) '<expr>]
      [else
       (define dat (and (syntax? val-stx) (syntax->datum val-stx)))
       (cond
         [(boolean? dat) dat]
         [(exact-integer? dat) dat]
         [(string? dat) dat]
         [(eq? dat 'null) 'null]
         [else '<expr>])]))

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

  (define (report-unknown-pkg src ref suggestions)
    (set! pkg-errors (+ pkg-errors 1))
    (set! total-errors (+ total-errors 1))
    (define stx (pkg-ref-src-stx ref))
    (define line (or (and stx (syntax-line stx)) "?"))
    (define col  (or (and stx (syntax-column stx)) "?"))
    (eprintf "~a:~a:~a: unknown package ~a in ~a set\n"
             src line col (pkg-ref-name ref) (pkg-ref-set ref))
    (when (not (null? suggestions))
      (eprintf "  did you mean: ~a?\n"
               (string-join suggestions ", " #:before-last " or "))))

  (define (report-duplicate-assignment src path first-line line col)
    (set! total-errors (+ total-errors 1))
    (eprintf "~a:~a:~a: duplicate assignment to ~a (first set at line ~a)\n"
             src line col path first-line))

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
    ;; Duplicate detection: path → (list (cons line col))
    (define path-assignments (make-hash))
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
                ;; Option path validation
                (for ([pr (in-list (extract-from-form s))])
                  (define p (path-ref-path pr))
                  (define stx-loc (path-ref-stx pr))
                  (define val-stx (path-ref-val-stx pr))
                  ;; Track assignments for duplicate detection
                  (when val-stx
                    (define loc (cons (or (syntax-line stx-loc) 0)
                                     (or (syntax-column stx-loc) 0)))
                    (hash-update! path-assignments p (λ (v) (cons loc v)) '())
                    ;; Track for cross-file conflict detection
                    (define xf-entry
                      (list src
                            (or (syntax-line stx-loc) 0)
                            (or (syntax-column stx-loc) 0)
                            (summarize-val val-stx)))
                    (hash-update! cross-file-assignments p
                                  (λ (v) (cons xf-entry v)) '()))
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
                    [else (void)]))
                ;; Package validation
                (when (and (pkg-cache-loaded? PKG-STATE) (not (NO-PACKAGES?)))
                  (for ([ref (in-list (extract-pkg-refs-from-form s))])
                    (define result (validate-pkg-ref PKG-STATE ref))
                    (when (and (pair? result) (eq? (car result) 'unknown))
                      (report-unknown-pkg src ref (cadr result))))))))
          (loop))))
    ;; Report duplicates
    (for ([(path locs) (in-hash path-assignments)])
      (when (> (length locs) 1)
        (define sorted (sort locs < #:key car))
        (define first-line (car (car sorted)))
        (for ([loc (in-list (cdr sorted))])
          (report-duplicate-assignment src path first-line (car loc) (cdr loc))))))

  ;; List-type options that are designed for multi-module contribution.
  ;; These are never flagged as cross-file conflicts.
  (define LIST-TYPED-SKIP-TYPES '("listOf"))

  (define (option-is-list-type? path)
    (define entry (schema-lookup/wildcard STATE path))
    (and entry
         (let ([t (hash-ref entry 't #f)])
           (and t (member t LIST-TYPED-SKIP-TYPES) #t))))

  ;; Detect cross-file conflicts: multiple files setting the same scalar
  ;; option to different values.
  (define (check-cross-file-conflicts!)
    (for ([(path entries) (in-hash cross-file-assignments)])
      ;; Only care if multiple files contribute
      (define files-involved
        (remove-duplicates (map car entries)))
      (when (> (length files-involved) 1)
        ;; Skip list-typed options (designed for multi-module contribution)
        (unless (option-is-list-type? path)
          ;; Collect unique known values
          (define vals (map (λ (e) (list-ref e 3)) entries))
          (define known-vals (filter (λ (v) (not (eq? v '<expr>))) vals))
          (define unique-known (remove-duplicates known-vals))
          ;; Conflict exists if:
          ;; - Two or more distinct known literals exist, OR
          ;; - We skip if all known values are the same (benign duplication)
          (when (> (length unique-known) 1)
            (set! cross-file-conflicts (+ cross-file-conflicts 1))
            (eprintf "warning: option ~a set by multiple modules with different values:\n"
                     path)
            ;; Group by file, show one entry per file (first occurrence)
            (define seen-files (make-hash))
            (for ([e (in-list (reverse entries))])
              (define file (car e))
              (unless (hash-has-key? seen-files file)
                (hash-set! seen-files file #t)
                (define line (list-ref e 1))
                (define col (list-ref e 2))
                (define val (list-ref e 3))
                (define val-str
                  (cond
                    [(string? val) (format "~s" val)]
                    [(boolean? val) (if val "#t" "#f")]
                    [(eq? val 'null) "null"]
                    [(number? val) (format "~a" val)]
                    [else "<expr>"]))
                (eprintf "  ~a:~a:~a: ~a\n" file line col val-str))))))))

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

  ;; Cross-file conflict detection (after all files are validated)
  (check-cross-file-conflicts!)

  (when (and (AUTO-FIX?) (positive? auto-fixes-applied))
    (printf "nisp validate: applied ~a auto-fix(es). Re-run to verify.\n" auto-fixes-applied))

  (when (positive? cross-file-conflicts)
    (eprintf "nisp validate: ~a cross-module conflict(s) (non-list options set by multiple files with different values)\n"
             cross-file-conflicts))

  (if (zero? total-errors)
      (printf "nisp validate: clean — no errors.\n")
      (begin
        (when (positive? pkg-errors)
          (eprintf "  (~a package error(s))\n" pkg-errors))
        (eprintf "\n~a error(s).\n" total-errors)))

  (exit (if (zero? total-errors) 0 1)))
