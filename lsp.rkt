#lang racket/base

;; nisp/lsp — Language Server Protocol implementation for #lang nisp.
;;
;; Reuses nisp/validate primitives for the actual checking. Runs as a
;; subprocess of the editor; speaks LSP over stdio (JSON-RPC).
;;
;; Capabilities (v0.6.0):
;;   - textDocument/publishDiagnostics: unknown options, type mismatches,
;;     enum violations, attrsOf-leaf nesting bugs — same checks as
;;     nisp-validate, surfaced as LSP diagnostics
;;   - textDocument/hover: hovering over an option path returns its
;;     schema entry (type, default, enum)
;;   - textDocument/completion: typing a partial option path returns
;;     matching schema entries

(require racket/port
         racket/string
         racket/list
         racket/path
         racket/file
         racket/match
         json
         (only-in nisp/validate
                  walk-syntax
                  extract-from-form
                  path-ref-path
                  path-ref-stx
                  path-ref-val-stx
                  infer-value-type
                  check-type
                  find-similar-strs))

(provide start-lsp)

;; ============================================================================
;; JSON-RPC over stdio
;; ============================================================================

(define (read-message in)
  ;; LSP frames messages with `Content-Length: N\r\n\r\n` header.
  (define headers (make-hash))
  (let loop ()
    (define line (read-line in 'return-linefeed))
    (cond
      [(eof-object? line) #f]
      [(equal? line "")
       ;; Body follows
       (define len (string->number (hash-ref headers "Content-Length" "0")))
       (cond
         [(or (not len) (zero? len)) #f]
         [else
          (define body-bytes (read-bytes len in))
          (read-json (open-input-bytes body-bytes))])]
      [else
       (define m (regexp-match #px"^([^:]+):\\s*(.*)$" line))
       (when m
         (hash-set! headers (cadr m) (caddr m)))
       (loop)])))

(define (write-message out msg)
  (define body (jsexpr->bytes msg))
  (fprintf out "Content-Length: ~a\r\n\r\n" (bytes-length body))
  (write-bytes body out)
  (flush-output out))

(define (notify out method params)
  (write-message out (hasheq 'jsonrpc "2.0"
                             'method method
                             'params params)))

(define (respond out id result)
  (write-message out (hasheq 'jsonrpc "2.0"
                             'id id
                             'result result)))

(define (respond-error out id code message)
  (write-message out (hasheq 'jsonrpc "2.0"
                             'id id
                             'error (hasheq 'code code 'message message))))

;; ============================================================================
;; Document store + schema loading
;; ============================================================================

(define documents (make-hash))   ; uri → text
(define schema-table (make-hash))
(define schema-loaded? #f)

(define (uri->path uri)
  ;; file:///foo/bar.rkt → /foo/bar.rkt
  (cond
    [(regexp-match #rx"^file://(.+)$" uri) => cadr]
    [else uri]))

(define (find-cache-dir doc-uri)
  (define p (uri->path doc-uri))
  (let loop ([d (if (file-exists? p) (path-only p) (string->path p))])
    (cond
      [(not d) #f]
      [(directory-exists? (build-path d ".nisp-cache"))
       (build-path d ".nisp-cache")]
      [(file-exists? (build-path d "flake.rkt"))
       (build-path d ".nisp-cache")]
      [(file-exists? (build-path d "flake.nix"))
       (build-path d ".nisp-cache")]
      [else
       (define-values (parent _ _isdir) (split-path d))
       (cond
         [(or (not parent) (eq? parent 'relative)) #f]
         [else (loop parent)])])))

(define (ensure-schema-loaded! example-uri)
  (unless schema-loaded?
    (define cd (find-cache-dir example-uri))
    (when cd
      (define schema-path (build-path cd "schema.json"))
      (define sub-path    (build-path cd "schema-submodules.json"))
      (with-handlers ([exn:fail? void])
        (when (file-exists? schema-path)
          (for ([e (in-list (call-with-input-file schema-path read-json))])
            (hash-set! schema-table (hash-ref e 'p) e)))
        (when (file-exists? sub-path)
          (define sd (call-with-input-file sub-path read-json))
          (for* ([(_prefix entries) (in-hash (hash-ref sd 'submodules (hash)))]
                 [e (in-list entries)])
            (hash-set! schema-table (hash-ref e 'p) e))))
      (set! schema-loaded? #t))))

;; ============================================================================
;; Validation
;; ============================================================================

(define (count-char-in c s)
  (for/sum ([ch (in-string s)] #:when (char=? ch c)) 1))

(define (parse-document-syntax src text)
  ;; Strip the `#lang nisp` line so read-syntax can consume the rest.
  (define-values (lang-prefix rest)
    (let ([m (regexp-match-positions #rx"^#lang [^\n]*\n" text)])
      (cond
        [m (values (substring text 0 (cdr (car m)))
                   (substring text (cdr (car m))))]
        [else (values "" text)])))
  (define padded (string-append (make-string (count-char-in #\newline lang-prefix) #\newline)
                                rest))
  (define port (open-input-string padded))
  (port-count-lines! port)
  (with-handlers ([exn:fail:read?
                   (λ (e) (cons 'parse-error (exn-message e)))])
    (let loop ([acc '()])
      (define stx (read-syntax src port))
      (cond
        [(eof-object? stx) (reverse acc)]
        [else (loop (cons stx acc))]))))

(define SUBMODULE-TYPES
  '("attrsOf" "submodule" "lazyAttrsOf" "listOf" "oneOf" "either"
    "functionTo" "unspecified"))

(define (in-submodule? path)
  (let loop ([parts (regexp-split #rx"\\." path)])
    (cond
      [(null? parts) #f]
      [(null? (cdr parts)) #f]
      [else
       (define prefix-parts (drop-right parts 1))
       (define prefix (string-join prefix-parts "."))
       (define entry (hash-ref schema-table prefix #f))
       (define t (and entry (hash-ref entry 't #f)))
       (cond [(and t (member t SUBMODULE-TYPES)) #t]
             [else (loop prefix-parts)])])))

(define (validate-document uri text)
  ;; Returns list of LSP-style diagnostic hashes.
  (ensure-schema-loaded! uri)
  (define src (uri->path uri))
  (define diagnostics '())
  (define (add-diag! line col-start col-end severity msg [code #f])
    (set! diagnostics
          (cons (hasheq 'range (hasheq 'start (hasheq 'line line 'character col-start)
                                       'end   (hasheq 'line line 'character col-end))
                        'severity severity   ; 1=Error 2=Warning 3=Info 4=Hint
                        'source "nisp"
                        'message msg
                        'code (or code "nisp-error"))
                diagnostics)))
  (define stxs-or-err (parse-document-syntax src text))
  (cond
    [(and (pair? stxs-or-err) (eq? (car stxs-or-err) 'parse-error))
     (add-diag! 0 0 1 1 (cdr stxs-or-err) "parse-error")]
    [else
     (for ([stx (in-list stxs-or-err)])
       (walk-syntax stx
         (λ (s in-hm?)
           (unless in-hm?
             (for ([pr (in-list (extract-from-form s))])
               (define p (path-ref-path pr))
               (define stx-loc (path-ref-stx pr))
               (define val-stx (path-ref-val-stx pr))
               (cond
                 [(hash-has-key? schema-table p)
                  ;; Phase 2: type check
                  (when val-stx
                    (define entry (hash-ref schema-table p))
                    (define vt (infer-value-type val-stx))
                    (define result (check-type entry vt))
                    (when (and (pair? result) (eq? (car result) 'mismatch))
                      (define line (or (and val-stx (syntax-line val-stx)) 1))
                      (define col (or (and val-stx (syntax-column val-stx)) 0))
                      (add-diag! (- line 1) col (+ col 10) 1
                                 (format "type mismatch at ~a: ~a" p (cadr result))
                                 "type-mismatch")))]
                 [(in-submodule? p) (void)]
                 [else
                  (define line (or (syntax-line stx-loc) 1))
                  (define col  (or (syntax-column stx-loc) 0))
                  (define sims (find-similar-strs p (hash-keys schema-table) 3))
                  (define msg
                    (cond [(null? sims) (format "unknown option ~a" p)]
                          [else (format "unknown option ~a — did you mean: ~a?"
                                        p (string-join sims ", "))]))
                  (add-diag! (- line 1) col (+ col (string-length p)) 1
                             msg "unknown-option")]))))))])
  (reverse diagnostics))

(define (publish-diagnostics! out uri text)
  (define diags (validate-document uri text))
  (notify out "textDocument/publishDiagnostics"
          (hasheq 'uri uri 'diagnostics diags)))

;; ============================================================================
;; Hover + completion
;; ============================================================================

(define (text-at-position text line character)
  ;; Extract the option-path-shaped token surrounding the cursor.
  (define lines (regexp-split #rx"\n" text))
  (cond
    [(>= line (length lines)) #f]
    [else
     (define ln (list-ref lines line))
     (define len (string-length ln))
     (define ch (min character len))
     ;; Walk left and right for chars matching [a-zA-Z0-9_.-]
     (define (path-char? c)
       (or (char-alphabetic? c) (char-numeric? c)
           (member c '(#\. #\_ #\-))))
     (define lo
       (let loop ([i ch])
         (cond [(or (zero? i) (not (path-char? (string-ref ln (- i 1))))) i]
               [else (loop (- i 1))])))
     (define hi
       (let loop ([i ch])
         (cond [(or (>= i len) (not (path-char? (string-ref ln i)))) i]
               [else (loop (+ i 1))])))
     (cond
       [(= lo hi) #f]
       [else (substring ln lo hi)])]))

(define (handle-hover params)
  (define uri (hash-ref (hash-ref params 'textDocument) 'uri))
  (define pos (hash-ref params 'position))
  (define line (hash-ref pos 'line))
  (define char (hash-ref pos 'character))
  (define text (hash-ref documents uri #f))
  (cond
    [(not text) (hash 'contents "")]
    [else
     (ensure-schema-loaded! uri)
     (define word (text-at-position text line char))
     (define entry (and word (hash-ref schema-table word #f)))
     (cond
       [entry
        (define t (hash-ref entry 't "?"))
        (define inner (hash-ref entry 'inner #f))
        (define enum (hash-ref entry 'enum #f))
        (define lines
          (filter
           values
           (list
            (format "**`~a`**" word)
            ""
            (format "type: `~a`" (describe-type t inner))
            (and enum (format "enum: ~a"
                              (string-join (map (λ (v) (format "`~s`" v)) enum) ", "))))))
        (hash 'contents (hasheq 'kind "markdown"
                                'value (string-join lines "\n")))]
       [else (hash 'contents "")])]))

(define (describe-type t inner)
  (cond
    [(member t '("listOf" "nullOr" "attrsOf" "lazyAttrsOf"))
     (define inner-t (and inner (hash-ref inner 't "?")))
     (define inner-inner (and inner (hash-ref inner 'inner #f)))
     (format "~a (~a)" t (describe-type inner-t inner-inner))]
    [(string? t) t]
    [else "?"]))

(define (handle-completion params)
  (define uri (hash-ref (hash-ref params 'textDocument) 'uri))
  (define pos (hash-ref params 'position))
  (define line (hash-ref pos 'line))
  (define char (hash-ref pos 'character))
  (define text (hash-ref documents uri #f))
  (cond
    [(not text) (hasheq 'isIncomplete #f 'items '())]
    [else
     (ensure-schema-loaded! uri)
     (define word (or (text-at-position text line char) ""))
     (define matches
       (for/list ([(p e) (in-hash schema-table)]
                  #:when (and (string? p)
                              (string-prefix? p word)))
         (define t (hash-ref e 't "?"))
         (define inner (hash-ref e 'inner #f))
         (hasheq 'label p
                 'kind 14   ; Property
                 'detail (describe-type t inner))))
     (define sorted
       (sort matches string<? #:key (λ (h) (hash-ref h 'label))))
     (define limited (if (> (length sorted) 100) (take sorted 100) sorted))
     (hasheq 'isIncomplete (> (length sorted) 100)
             'items limited)]))

;; ============================================================================
;; Dispatch
;; ============================================================================

(define (handle-message msg out)
  (define id (hash-ref msg 'id #f))
  (define method (hash-ref msg 'method ""))
  (define params (hash-ref msg 'params (hasheq)))
  (cond
    ;; Requests (have id, expect response)
    [(equal? method "initialize")
     (respond out id
              (hasheq 'capabilities
                      (hasheq 'textDocumentSync 1   ; full sync
                              'hoverProvider #t
                              'completionProvider
                              (hasheq 'triggerCharacters (list "." "_")
                                      'resolveProvider #f))
                      'serverInfo (hasheq 'name "nisp-lsp" 'version "0.6.0")))]
    [(equal? method "textDocument/hover")
     (respond out id (handle-hover params))]
    [(equal? method "textDocument/completion")
     (respond out id (handle-completion params))]
    [(equal? method "shutdown")
     (respond out id (json-null))]

    ;; Notifications (no id, no response)
    [(equal? method "initialized") (void)]
    [(equal? method "exit") (exit 0)]
    [(equal? method "textDocument/didOpen")
     (define doc (hash-ref params 'textDocument))
     (define uri (hash-ref doc 'uri))
     (define text (hash-ref doc 'text))
     (hash-set! documents uri text)
     (publish-diagnostics! out uri text)]
    [(equal? method "textDocument/didChange")
     (define uri (hash-ref (hash-ref params 'textDocument) 'uri))
     (define changes (hash-ref params 'contentChanges))
     (when (pair? changes)
       (define new-text (hash-ref (last changes) 'text))
       (hash-set! documents uri new-text)
       (publish-diagnostics! out uri new-text))]
    [(equal? method "textDocument/didClose")
     (define uri (hash-ref (hash-ref params 'textDocument) 'uri))
     (hash-remove! documents uri)
     (notify out "textDocument/publishDiagnostics"
             (hasheq 'uri uri 'diagnostics '()))]

    ;; Ignore unknown notifications, error on unknown requests.
    [id (respond-error out id -32601 (format "method not found: ~a" method))]
    [else (void)]))

(define (start-lsp [in (current-input-port)] [out (current-output-port)])
  (file-stream-buffer-mode out 'none)
  (let loop ()
    (define msg (read-message in))
    (cond
      [(not msg) (void)]
      [else
       (with-handlers ([exn:fail?
                        (λ (e)
                          (define id (hash-ref msg 'id #f))
                          (when id
                            (respond-error out id -32603
                                           (format "internal error: ~a" (exn-message e)))))])
         (handle-message msg out))
       (loop)])))
