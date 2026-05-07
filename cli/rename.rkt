#lang racket/base

;; nisp rename — rename an option path across all .rkt files in the flake.
;;
;; Usage:
;;   nisp rename <old.path> <new.path>             # apply
;;   nisp rename --dry-run <old.path> <new.path>   # show planned changes
;;
;; Word-boundary matching avoids partial collisions (renaming
;; `services.openssh` won't touch `services.opensshd`). Skips matches
;; inside `"…"` string literals.

(require racket/cmdline
         racket/file
         racket/string
         racket/list
         racket/path)

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

(define (main)
  (define DRY-RUN? (make-parameter #f))
  (define ROOT-OVERRIDE (make-parameter #f))

  (define rest-args
    (command-line
     #:program "nisp rename"
     #:once-each
     [("--dry-run") "show planned changes without applying"
      (DRY-RUN? #t)]
     [("--root") d "flake root (default: cwd's git toplevel)"
      (ROOT-OVERRIDE d)]
     #:args args
     args))

  (unless (= (length rest-args) 2)
    (eprintf "usage: nisp rename [--dry-run] <old.path> <new.path>\n")
    (exit 2))

  (define OLD (car rest-args))
  (define NEW (cadr rest-args))
  (define ROOT
    (cond [(ROOT-OVERRIDE) (path->complete-path (ROOT-OVERRIDE))]
          [else (find-flake-root)]))

  (define (target-files)
    (sort
     (for/list ([f (in-directory ROOT)]
                #:when (let ([s (path->string f)])
                         (and (regexp-match? #rx"\\.rkt$" s)
                              (not (regexp-match? #rx"/scripts/" s))
                              (not (regexp-match? #rx"/tests/" s))
                              (not (regexp-match? #rx"/\\.firn-build/" s))
                              (not (regexp-match? #rx"/\\.nisp-cache/" s))
                              (not (regexp-match? #rx"/\\.direnv/" s))
                              (not (regexp-match? #rx"/\\.git/" s))
                              (not (regexp-match? #rx"/result" s))
                              (with-handlers ([exn:fail? (λ (_) #f)])
                                (regexp-match?
                                 #rx"^#lang nisp"
                                 (call-with-input-file f
                                   (λ (p) (read-line p))))))))
       f)
     string<? #:key path->string))

  (define OLD-RE
    (regexp (string-append "(?<![a-zA-Z0-9_-])" (regexp-quote OLD) "(?=$|[^a-zA-Z0-9_-])")))

  (define (in-string-literal? line offset)
    (define before (substring line 0 offset))
    (define quote-count
      (for/sum ([m (in-list (regexp-match* #px"(?<!\\\\)\"" before))]) 1))
    (odd? quote-count))

  (define (rewrite-line line)
    (define count 0)
    (define result
      (regexp-replace*
       OLD-RE line
       (λ (m)
         (set! count (+ count 1))
         NEW)))
    (cond
      [(zero? count) (values line 0)]
      [else
       (define matches (regexp-match-positions* OLD-RE line))
       (define safe?
         (for/and ([range (in-list matches)])
           (not (in-string-literal? line (car range)))))
       (cond
         [safe? (values result count)]
         [else (values line 0)])]))

  (define (rewrite-file path)
    (define lines (regexp-split #rx"\n" (file->string path)))
    (define rewritten
      (for/list ([line (in-list lines)])
        (define-values (new n) (rewrite-line line))
        (cons new n)))
    (define total (apply + (map cdr rewritten)))
    (cond
      [(zero? total) (values #f 0)]
      [else (values (string-join (map car rewritten) "\n") total)]))

  (define files (target-files))
  (printf "scanning ~a .rkt files for `~a` → `~a`...\n" (length files) OLD NEW)

  (define total-edits 0)
  (define files-changed 0)

  (for ([f (in-list files)])
    (define-values (new-text count) (rewrite-file f))
    (when (positive? count)
      (set! total-edits (+ total-edits count))
      (set! files-changed (+ files-changed 1))
      (define rel (path->string (find-relative-path ROOT f)))
      (cond
        [(DRY-RUN?)
         (printf "  ~a — ~a edit(s)\n" rel count)]
        [else
         (display-to-file new-text f #:exists 'replace)
         (printf "  ~a — ~a edit(s) applied\n" rel count)])))

  (cond
    [(zero? total-edits)
     (printf "no occurrences of `~a` found.\n" OLD)
     (exit 1)]
    [else
     (printf "~a edit(s) across ~a file(s)~a.\n"
             total-edits files-changed
             (if (DRY-RUN?) " (dry run — no changes written)" ""))
     (unless (DRY-RUN?)
       (printf "next: run `nisp validate` to verify.\n"))]))
