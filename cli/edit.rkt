#lang racket/base

;; nisp edit — programmatic edits to nisp source files.
;;
;; Source-text-preserving (uses Racket's read-syntax to locate AST nodes,
;; does text-level surgery using their byte positions). Comments and
;; formatting outside the edited region are preserved.
;;
;; Usage:
;;   nisp edit set <file> <option-path> <value-text>     replace value, or insert
;;   nisp edit unset <file> <option-path>                remove the (set …) form
;;   nisp edit enable-add <file> <option-path>           add to (enable …) list
;;   nisp edit enable-remove <file> <option-path>        remove from (enable …)
;;
;; <value-text> is raw nisp source, e.g.:
;;   nisp edit set hosts/whiterabbit/configuration.rkt myConfig.modules.foo.port 8080
;;   nisp edit set hosts/laptop/configuration.rkt services.bluetooth.enable '#t'

(require racket/cmdline
         racket/file
         (only-in nisp/edit
                  edit-set edit-unset
                  edit-enable-add edit-enable-remove))

(provide main)

(define (main)
  (define args
    (command-line
     #:program "nisp edit"
     #:args args args))

  (when (< (length args) 2)
    (eprintf "usage: nisp edit <op> <file> <args...>\n")
    (eprintf "  ops: set, unset, enable-add, enable-remove\n")
    (exit 2))

  (define op (car args))
  (define rest (cdr args))

  (define (read-file path) (file->string path))
  (define (write-file path text) (display-to-file text path #:exists 'replace))

  (case op
    [("set")
     (when (not (= (length rest) 3))
       (eprintf "usage: nisp edit set <file> <option-path> <value>\n")
       (exit 2))
     (define file (car rest))
     (define path (cadr rest))
     (define value (caddr rest))
     (define src (read-file file))
     (define updated (edit-set src path value))
     (write-file file updated)
     (printf "set ~a in ~a\n" path file)]
    [("unset")
     (when (not (= (length rest) 2))
       (eprintf "usage: nisp edit unset <file> <option-path>\n")
       (exit 2))
     (define file (car rest))
     (define path (cadr rest))
     (define src (read-file file))
     (define updated (edit-unset src path))
     (cond
       [(equal? src updated)
        (eprintf "no `(set '~a …)` form found in ~a\n" path file)
        (exit 1)]
       [else
        (write-file file updated)
        (printf "unset ~a in ~a\n" path file)])]
    [("enable-add")
     (when (not (= (length rest) 2))
       (eprintf "usage: nisp edit enable-add <file> <option-path>\n")
       (exit 2))
     (define file (car rest))
     (define path (cadr rest))
     (define src (read-file file))
     (define updated (edit-enable-add src path))
     (cond
       [(equal? src updated)
        (printf "~a already enabled in ~a\n" path file)]
       [else
        (write-file file updated)
        (printf "enabled ~a in ~a\n" path file)])]
    [("enable-remove")
     (when (not (= (length rest) 2))
       (eprintf "usage: nisp edit enable-remove <file> <option-path>\n")
       (exit 2))
     (define file (car rest))
     (define path (cadr rest))
     (define src (read-file file))
     (define updated (edit-enable-remove src path))
     (cond
       [(equal? src updated)
        (eprintf "~a not in any (enable …) form in ~a\n" path file)
        (exit 1)]
       [else
        (write-file file updated)
        (printf "removed ~a from (enable …) in ~a\n" path file)])]
    [else
     (eprintf "unknown op: ~a (expected: set | unset | enable-add | enable-remove)\n" op)
     (exit 2)]))
