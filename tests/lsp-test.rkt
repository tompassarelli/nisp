#lang racket/base

;; lsp-test — subprocess JSON-RPC tests for nisp-lsp.

(require rackunit
         racket/port
         racket/system
         racket/runtime-path
         json)

(define-runtime-path NISP-DIR "..")

(define FIRNOS-ROOT
  (let ([p (build-path (find-system-path 'home-dir) "code" "nixos-config")])
    (and (directory-exists? p) (directory-exists? (build-path p ".nisp-cache"))
         p)))

;; LSP messages are framed `Content-Length: N\r\n\r\n<JSON>`. Helpers:

(define (write-msg out payload)
  (define body (jsexpr->bytes payload))
  (fprintf out "Content-Length: ~a\r\n\r\n" (bytes-length body))
  (write-bytes body out)
  (flush-output out))

(define (read-msg in)
  (define header (open-output-string))
  (let loop ()
    (define c (read-bytes 1 in))
    (cond
      [(eof-object? c) #f]
      [else
       (write-bytes c header)
       (cond
         [(regexp-match? #rx#"\r\n\r\n$" (get-output-string header))
          (define hs (get-output-string header))
          (define m (regexp-match #px"Content-Length:\\s*([0-9]+)" hs))
          (cond
            [m
             (define cl (string->number (cadr m)))
             (define body (read-bytes cl in))
             (read-json (open-input-bytes body))]
            [else #f])]
         [else (loop)])])))

(define (start-lsp [cwd FIRNOS-ROOT])
  (define-values (sub sub-out sub-in sub-err)
    (subprocess #f #f #f
                (path->string (build-path NISP-DIR "bin" "nisp-lsp"))))
  (values sub sub-in sub-out))

(define (close-lsp! sub stdin)
  (with-handlers ([exn:fail? void])
    (close-output-port stdin)
    (subprocess-wait sub)))

;; Only run if firnos cache exists (need a populated schema).
(when FIRNOS-ROOT

  (test-case "initialize handshake returns capabilities + version"
    (define-values (sub stdin stdout) (start-lsp))
    (write-msg stdin (hasheq 'jsonrpc "2.0" 'id 1 'method "initialize"
                             'params (hasheq 'capabilities (hasheq))))
    (define resp (read-msg stdout))
    (check-equal? (hash-ref resp 'id) 1)
    (define caps (hash-ref (hash-ref resp 'result) 'capabilities))
    (check-true (hash-ref caps 'hoverProvider))
    (check-true (hash-ref caps 'definitionProvider))
    (check-not-false (hash-ref caps 'codeActionProvider))
    (check-not-false (hash-ref caps 'completionProvider))
    (define info (hash-ref (hash-ref resp 'result) 'serverInfo))
    (check-equal? (hash-ref info 'name) "nisp-lsp")
    ;; Version is non-empty and not the fallback
    (check-not-equal? (hash-ref info 'version) "0.0.0")
    (close-lsp! sub stdin))

  (test-case "didOpen with bad path emits unknown-option diagnostic with did-you-mean"
    (define-values (sub stdin stdout) (start-lsp))
    (write-msg stdin (hasheq 'jsonrpc "2.0" 'id 1 'method "initialize"
                             'params (hasheq 'capabilities (hasheq))))
    (read-msg stdout)
    (write-msg stdin (hasheq 'jsonrpc "2.0" 'method "initialized" 'params (hasheq)))
    (define uri (string-append "file://" (path->string (build-path FIRNOS-ROOT "modules/test.rkt"))))
    (write-msg stdin (hasheq 'jsonrpc "2.0" 'method "textDocument/didOpen"
                             'params (hasheq 'textDocument
                                             (hasheq 'uri uri 'languageId "racket"
                                                     'version 1
                                                     'text "#lang nisp\n\n(set 'services.opensh.enable #t)\n"))))
    (define notif (read-msg stdout))
    (check-equal? (hash-ref notif 'method) "textDocument/publishDiagnostics")
    (define diags (hash-ref (hash-ref notif 'params) 'diagnostics))
    (check-true (>= (length diags) 1))
    (define d (car diags))
    (check-equal? (hash-ref d 'code) "unknown-option")
    (check-true (regexp-match? #rx"did you mean" (hash-ref d 'message)))
    (define data (hash-ref d 'data #f))
    (check-not-false data)
    (check-true (>= (length (hash-ref data 'suggestions)) 1))
    (close-lsp! sub stdin))

  (test-case "codeAction returns quickfix per suggestion"
    (define-values (sub stdin stdout) (start-lsp))
    (write-msg stdin (hasheq 'jsonrpc "2.0" 'id 1 'method "initialize"
                             'params (hasheq 'capabilities (hasheq))))
    (read-msg stdout)
    (write-msg stdin (hasheq 'jsonrpc "2.0" 'method "initialized" 'params (hasheq)))
    (define uri (string-append "file://" (path->string (build-path FIRNOS-ROOT "modules/test.rkt"))))
    (write-msg stdin (hasheq 'jsonrpc "2.0" 'method "textDocument/didOpen"
                             'params (hasheq 'textDocument
                                             (hasheq 'uri uri 'languageId "racket"
                                                     'version 1
                                                     'text "#lang nisp\n\n(set 'services.opensh.enable #t)\n"))))
    (define notif (read-msg stdout))
    (define diags (hash-ref (hash-ref notif 'params) 'diagnostics))
    (write-msg stdin (hasheq 'jsonrpc "2.0" 'id 2 'method "textDocument/codeAction"
                             'params (hasheq 'textDocument (hasheq 'uri uri)
                                             'range (hash-ref (car diags) 'range)
                                             'context (hasheq 'diagnostics diags))))
    (define resp (read-msg stdout))
    (define actions (hash-ref resp 'result))
    (check-true (>= (length actions) 1))
    (define a (car actions))
    (check-equal? (hash-ref a 'kind) "quickfix")
    (check-true (regexp-match? #rx"Replace with" (hash-ref a 'title)))
    (close-lsp! sub stdin))

  (test-case "hover over option path returns markdown with type"
    (define-values (sub stdin stdout) (start-lsp))
    (write-msg stdin (hasheq 'jsonrpc "2.0" 'id 1 'method "initialize"
                             'params (hasheq 'capabilities (hasheq))))
    (read-msg stdout)
    (write-msg stdin (hasheq 'jsonrpc "2.0" 'method "initialized" 'params (hasheq)))
    (define uri (string-append "file://" (path->string (build-path FIRNOS-ROOT "modules/test.rkt"))))
    (write-msg stdin (hasheq 'jsonrpc "2.0" 'method "textDocument/didOpen"
                             'params (hasheq 'textDocument
                                             (hasheq 'uri uri 'languageId "racket"
                                                     'version 1
                                                     'text "#lang nisp\n\n(set 'services.openssh.enable #t)\n"))))
    (read-msg stdout)
    (write-msg stdin (hasheq 'jsonrpc "2.0" 'id 2 'method "textDocument/hover"
                             'params (hasheq 'textDocument (hasheq 'uri uri)
                                             'position (hasheq 'line 2 'character 16))))
    (define resp (read-msg stdout))
    (define contents (hash-ref (hash-ref resp 'result) 'contents))
    (check-true (regexp-match? #rx"services\\.openssh\\.enable" (hash-ref contents 'value)))
    (check-true (regexp-match? #rx"bool" (hash-ref contents 'value)))
    (close-lsp! sub stdin)))
