#lang racket/base

;; edit-test — unit tests for nisp/edit (programmatic source edits).

(require rackunit
         (only-in nisp/edit
                  edit-set edit-unset
                  edit-enable-add edit-enable-remove
                  find-set-form-positions))

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

;; ---------- enable-add / enable-remove ----------

(define ENABLE-SAMPLE
  "#lang nisp

(host-file
  (enable myConfig.modules.boot
          myConfig.modules.networking)
  (set 'myConfig.modules.users.username \"tom\"))
")

(test-case "edit-enable-add: append to existing (enable …)"
  (define after (edit-enable-add ENABLE-SAMPLE "myConfig.modules.ssh"))
  (check-true (regexp-match? #rx"myConfig\\.modules\\.boot" after))
  (check-true (regexp-match? #rx"myConfig\\.modules\\.networking" after))
  (check-true (regexp-match? #rx"myConfig\\.modules\\.ssh" after)))

(test-case "edit-enable-add: idempotent if already present"
  (define after (edit-enable-add ENABLE-SAMPLE "myConfig.modules.boot"))
  (check-equal? after ENABLE-SAMPLE))

(test-case "edit-enable-add: insert new form when no (enable …) exists"
  (define src "#lang nisp\n(host-file\n  (set 'foo \"bar\"))\n")
  (define after (edit-enable-add src "myConfig.modules.boot"))
  (check-true (regexp-match? #rx"\\(enable myConfig\\.modules\\.boot\\)" after)))

(test-case "edit-enable-remove: drops one path, leaves others"
  (define after (edit-enable-remove ENABLE-SAMPLE "myConfig.modules.networking"))
  (check-true (regexp-match? #rx"myConfig\\.modules\\.boot" after))
  (check-false (regexp-match? #rx"myConfig\\.modules\\.networking" after))
  ;; Form is preserved (still has boot)
  (check-true (regexp-match? #rx"\\(enable" after)))

(test-case "edit-enable-remove: removes form entirely if path was only arg"
  (define src "#lang nisp\n(host-file\n  (enable myConfig.modules.lonely)\n  (set 'foo \"bar\"))\n")
  (define after (edit-enable-remove src "myConfig.modules.lonely"))
  (check-false (regexp-match? #rx"myConfig\\.modules\\.lonely" after))
  (check-false (regexp-match? #rx"\\(enable" after))
  (check-true (regexp-match? #rx"\\(set 'foo" after)))

(test-case "edit-enable-remove: no-op if path absent"
  (define after (edit-enable-remove ENABLE-SAMPLE "myConfig.modules.absent"))
  (check-equal? after ENABLE-SAMPLE))

(test-case "edit-enable-remove: handles 'quoted form too"
  (define src "#lang nisp\n(host-file\n  (enable 'myConfig.modules.a 'myConfig.modules.b))\n")
  (define after (edit-enable-remove src "myConfig.modules.a"))
  (check-false (regexp-match? #rx"myConfig\\.modules\\.a" after))
  (check-true (regexp-match? #rx"myConfig\\.modules\\.b" after)))
