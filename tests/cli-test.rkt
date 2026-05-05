#lang racket/base

;; cli-test — subprocess tests for the CLI tools (schema, rename, lsp).
;;
;; Each CLI is invoked via `system*` against fixture files / inputs;
;; we regex-match expected output. The schema CLI needs a populated
;; .nisp-cache; we point it at firnos's cache (assumed populated as
;; part of dev workflow).

(require rackunit
         racket/port
         racket/system
         racket/runtime-path
         racket/file
         racket/path
         json)

(define-runtime-path NISP-DIR "..")

(define (nisp-bin name) (build-path NISP-DIR "bin" name))

(define FIRNOS-CACHE
  (let ([p (build-path (find-system-path 'home-dir)
                       "code" "nixos-config" ".nisp-cache")])
    (and (directory-exists? p) p)))

(define (run-cli script . args)
  ;; Returns (values stdout stderr exit).
  (define out (open-output-string))
  (define err (open-output-string))
  (define rc
    (parameterize ([current-output-port out] [current-error-port err])
      (apply system* (path->string script) args)))
  (values (get-output-string out)
          (get-output-string err)
          (if rc 0 1)))

;; ---------- nisp-schema ----------

(when FIRNOS-CACHE
  (test-case "nisp-schema: exact lookup"
    (define-values (out _err rc)
      (run-cli (nisp-bin "nisp-schema")
               "--cache-dir" (path->string FIRNOS-CACHE)
               "services.openssh.enable"))
    (check-equal? rc 0)
    (check-true (regexp-match? #px"type:\\s+bool" out)))

  (test-case "nisp-schema: --json"
    (define-values (out _err rc)
      (run-cli (nisp-bin "nisp-schema")
               "--cache-dir" (path->string FIRNOS-CACHE)
               "--json"
               "services.openssh.enable"))
    (check-equal? rc 0)
    (define data (read-json (open-input-string out)))
    (check-equal? (hash-ref data 't) "bool"))

  (test-case "nisp-schema: --search returns multiple matches"
    (define-values (out _err rc)
      (run-cli (nisp-bin "nisp-schema")
               "--cache-dir" (path->string FIRNOS-CACHE)
               "--search" "openssh"))
    (check-equal? rc 0)
    (check-true (> (length (regexp-match* #rx"services\\.openssh" out)) 5)))

  (test-case "nisp-schema: --children lists sub-options"
    (define-values (out _err rc)
      (run-cli (nisp-bin "nisp-schema")
               "--cache-dir" (path->string FIRNOS-CACHE)
               "--children" "services.openssh"))
    (check-equal? rc 0)
    (check-true (regexp-match? #rx"services\\.openssh\\.enable" out)))

  (test-case "nisp-schema: did-you-mean on miss"
    (define-values (out err rc)
      (run-cli (nisp-bin "nisp-schema")
               "--cache-dir" (path->string FIRNOS-CACHE)
               "services.opensh.enable"))
    (check-not-equal? rc 0)
    (check-true (regexp-match? #rx"did you mean" err))))

;; ---------- nisp-rename ----------

(test-case "nisp-rename: dry-run shows planned edits"
  (define tmpdir (make-temporary-file "nisp-rename-test-~a" 'directory))
  (define rkt (build-path tmpdir "test.rkt"))
  (display-to-file
   "#lang nisp\n(set 'foo.bar.enable #t)\n(set 'foo.bar.port 22)\n"
   rkt)
  (define-values (out _err rc)
    (run-cli (nisp-bin "nisp-rename") "--dry-run" "--root" (path->string tmpdir)
             "foo.bar" "foo.baz"))
  (check-equal? rc 0)
  (check-true (regexp-match? #rx"2 edit\\(s\\)" out))
  ;; Source file unchanged
  (define after (file->string rkt))
  (check-true (regexp-match? #rx"foo\\.bar\\.enable" after))
  (delete-directory/files tmpdir))

(test-case "nisp-rename: applies edits"
  (define tmpdir (make-temporary-file "nisp-rename-test-~a" 'directory))
  (define rkt (build-path tmpdir "test.rkt"))
  (display-to-file
   "#lang nisp\n(set 'foo.bar.enable #t)\n"
   rkt)
  (define-values (_out _err rc)
    (run-cli (nisp-bin "nisp-rename") "--root" (path->string tmpdir)
             "foo.bar" "foo.baz"))
  (check-equal? rc 0)
  (define after (file->string rkt))
  (check-false (regexp-match? #rx"foo\\.bar\\.enable" after))
  (check-true (regexp-match? #rx"foo\\.baz\\.enable" after))
  (delete-directory/files tmpdir))

(test-case "nisp-rename: word-boundary prevents partial match"
  (define tmpdir (make-temporary-file "nisp-rename-test-~a" 'directory))
  (define rkt (build-path tmpdir "test.rkt"))
  (display-to-file
   "#lang nisp\n(set 'foo.bar.enable #t)\n(set 'foo.barbaz #t)\n"
   rkt)
  (define-values (_out _err rc)
    (run-cli (nisp-bin "nisp-rename") "--root" (path->string tmpdir)
             "foo.bar" "foo.qux"))
  (check-equal? rc 0)
  (define after (file->string rkt))
  ;; foo.bar.enable was renamed; foo.barbaz left alone
  (check-true (regexp-match? #rx"foo\\.qux\\.enable" after))
  (check-true (regexp-match? #rx"foo\\.barbaz" after))
  (delete-directory/files tmpdir))
