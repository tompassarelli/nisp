#lang racket/base

;; edit-test — unit tests for nisp/edit (programmatic source edits).

(require rackunit
         (only-in nisp/edit edit-set edit-unset find-set-form-positions))

(define SAMPLE
  "#lang nisp

(module-file modules test
  (desc \"test\")
  (config-body
    (set 'services.openssh.enable #t)
    (set 'services.openssh.port 22)))
")

(test-case "find-set-form-positions: locate by exact path"
  (define matches (find-set-form-positions SAMPLE "services.openssh.port"))
  (check-equal? (length matches) 1)
  (check-true (pair? (car matches))))

(test-case "find-set-form-positions: no match returns empty"
  (check-equal? (find-set-form-positions SAMPLE "services.nope") '()))

(test-case "edit-set: replace existing value"
  (define result (edit-set SAMPLE "services.openssh.port" "2222"))
  (check-true (regexp-match? #rx"port 2222" result))
  (check-false (regexp-match? #rx"port 22\\)" result)))

(test-case "edit-set: replace with structured value"
  (define result (edit-set SAMPLE "services.openssh.enable" "(mkforce #f)"))
  (check-true (regexp-match? #rx"enable \\(mkforce #f\\)" result)))

(test-case "edit-set: insert new option preserves existing"
  (define result (edit-set SAMPLE "services.openssh.permitRootLogin" "\"yes\""))
  (check-true (regexp-match? #rx"services\\.openssh\\.enable #t" result))
  (check-true (regexp-match? #rx"services\\.openssh\\.port 22" result))
  (check-true (regexp-match? #rx"permitRootLogin \"yes\"" result)))

(test-case "edit-set: insert lands at right indentation"
  (define result (edit-set SAMPLE "services.openssh.permitRootLogin" "\"yes\""))
  (check-true (regexp-match? #rx"    \\(set 'services\\.openssh\\.permitRootLogin"
                             result)))

(test-case "edit-unset: removes the form"
  (define result (edit-unset SAMPLE "services.openssh.port"))
  (check-false (regexp-match? #rx"services\\.openssh\\.port" result))
  (check-true (regexp-match? #rx"services\\.openssh\\.enable" result)))

(test-case "edit-unset: missing path is a no-op"
  (check-equal? (edit-unset SAMPLE "services.nope") SAMPLE))

(test-case "edit-set/unset: round-trip preserves comments"
  (define commented "#lang nisp

;; module description
(module-file modules t (desc \"x\") (config-body
  ;; the openssh service
  (set 'services.openssh.port 22)))
")
  (define after (edit-set commented "services.openssh.port" "2222"))
  ;; comments should still be present
  (check-true (regexp-match? #rx";; module description" after))
  (check-true (regexp-match? #rx";; the openssh service" after))
  (check-true (regexp-match? #rx"port 2222" after)))
