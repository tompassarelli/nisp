#lang racket/base

;; nisp import — translate Nix source → nisp source.
;;
;; Pipeline: stdin/file → nisp-nix-parser (Rust shim wrapping rnix) → JSON AST
;;        → this Racket code walks JSON → emits nisp source on stdout
;;
;; Usage:
;;   nisp import file.nix > file.rkt
;;   echo "{ a = 1; }" | nisp import > foo.rkt

(require racket/cmdline
         racket/string
         racket/list
         racket/port
         racket/system
         racket/runtime-path
         json)

(provide main)

(define-runtime-path THIS-DIR ".")

(define PARSER-CANDIDATES
  (list (build-path THIS-DIR ".." "nix-parser" "target" "release" "nisp-nix-parser")
        (build-path THIS-DIR ".." "nix-parser" "target" "debug" "nisp-nix-parser")))

(define (locate-parser-bin)
  (or (for/or ([p (in-list PARSER-CANDIDATES)])
        (and (file-exists? p) p))
      (find-executable-path "nisp-nix-parser")
      (begin
        (eprintf "nisp import: nisp-nix-parser binary not found.\n")
        (eprintf "  expected at: ~a\n" (path->string (car PARSER-CANDIDATES)))
        (eprintf "  build it:    cd nix-parser && cargo build --release\n")
        (exit 2))))

;; ---------- comment threading ----------
(define PENDING-COMMENTS (make-parameter '()))

(define (comment-start c) (hash-ref (hash-ref c 'pos) 'start))
(define (node-start n)
  (cond
    [(hash? n) (let ([p (hash-ref n 'pos #f)])
                 (and p (hash-ref p 'start #f)))]
    [else #f]))

(define INDENT "  ")
(define (indent n) (apply string-append (build-list n (λ (_) INDENT))))

(define (flush-comments-before! node-pos depth)
  (cond
    [(not node-pos) ""]
    [else
     (define ind (indent depth))
     (define out '())
     (define remaining
       (let loop ([cs (PENDING-COMMENTS)])
         (cond
           [(null? cs) cs]
           [(< (comment-start (car cs)) node-pos)
            (set! out (cons (format-comment (car cs) ind) out))
            (loop (cdr cs))]
           [else cs])))
     (PENDING-COMMENTS remaining)
     (cond
       [(null? out) ""]
       [else (string-append (apply string-append (reverse out)) ind)])]))

(define (flush-remaining-comments depth)
  (define ind (indent depth))
  (define out
    (apply string-append
           (map (λ (c) (format-comment c ind)) (PENDING-COMMENTS))))
  (PENDING-COMMENTS '())
  out)

(define (format-comment c ind)
  (define text (hash-ref c 'text))
  (define kind (hash-ref c 'kind "line"))
  (cond
    [(equal? kind "line")
     (define stripped (regexp-replace #px"^#\\s?" text ""))
     (format "~a;; ~a\n" ind stripped)]
    [else
     (define inner (regexp-replace #px"^/\\*\\s?" text ""))
     (define inner2 (regexp-replace #px"\\s?\\*/$" inner ""))
     (define lines (regexp-split #rx"\n" inner2))
     (apply string-append
            (map (λ (l) (format "~a;; ~a\n" ind (regexp-replace #px"^\\s+" l "")))
                 lines))]))

;; ---------- run the parser, get JSON ----------

(define (run-parser parser-bin source-text)
  (define-values (sub sub-out sub-in sub-err)
    (subprocess #f #f #f (path->string parser-bin)))
  (write-string source-text sub-in)
  (close-output-port sub-in)
  (define out-str (port->string sub-out))
  (define err-str (port->string sub-err))
  (close-input-port sub-out)
  (close-input-port sub-err)
  (subprocess-wait sub)
  (cond
    [(zero? (subprocess-status sub))
     (read-json (open-input-string out-str))]
    [else
     (eprintf "nisp import: parser failed:\n~a\n" err-str)
     (exit 1)]))

;; ---------- JSON AST → nisp source ----------

(define (kind-of node) (and (hash? node) (hash-ref node 'kind #f)))
(define (->str x) (cond [(string? x) x] [(symbol? x) (symbol->string x)] [else (format "~a" x)]))

(define (emit-expr node depth)
  (case (kind-of node)
    [("Integer") (number->string (hash-ref node 'value))]
    [("Float")   (number->string (hash-ref node 'value))]
    [("Uri")     (format "(s ~s)" (hash-ref node 'text))]
    [("Ident")   (emit-ident (hash-ref node 'name))]
    [("Path")    (emit-path node)]
    [("Str")     (emit-str node depth)]
    [("List")    (emit-list-node node depth)]
    [("AttrSet") (emit-attrset node depth)]
    [("BinOp")   (emit-binop node depth)]
    [("UnaryOp") (emit-unop node depth)]
    [("Apply")   (emit-apply node depth)]
    [("Select")  (emit-select node depth)]
    [("HasAttr") (emit-has-attr node depth)]
    [("Lambda")  (emit-lambda node depth)]
    [("LetIn")   (emit-letin node depth)]
    [("With")    (emit-with node depth)]
    [("IfElse")  (emit-ifelse node depth)]
    [("Assert")  (emit-assert node depth)]
    [("Paren")   (emit-expr (hash-ref node 'expr) depth)]
    [("LegacyLet")
     (format "(get (rec-att ~a) 'body)"
             (emit-entries (hash-ref node 'entries) (+ depth 1)))]
    [("Error") "(unparseable)"]
    [(#f) "null"]
    [else (format ";; UNHANDLED: ~a" (kind-of node))]))

(define (emit-ident name)
  (cond
    [(equal? name "true") "#t"]
    [(equal? name "false") "#f"]
    [(equal? name "null") "(nl)"]
    [else name]))

(define (emit-path node)
  (define parts (hash-ref node 'parts))
  (cond
    [(and (= (length parts) 1)
          (equal? (kind-of (car parts)) "Literal"))
     (format "(p ~s)" (hash-ref (car parts) 'text))]
    [else
     (format "(p ~s)"
             (apply string-append
                    (map (λ (p)
                           (case (kind-of p)
                             [("Literal") (hash-ref p 'text)]
                             [else (format "${~a}" (emit-expr (hash-ref p 'expr) 0))]))
                         parts)))]))

(define (emit-str node depth)
  (define parts (hash-ref node 'parts))
  (define indented? (hash-ref node 'indented #f))
  (cond
    [indented?
     (emit-mstring parts depth)]
    [(null? parts) "(s \"\")"]
    [(and (= (length parts) 1)
          (equal? (kind-of (car parts)) "Literal"))
     (format "~s" (hash-ref (car parts) 'text))]
    [else
     (define rendered
       (map (λ (p)
              (case (kind-of p)
                [("Literal") (format "~s" (hash-ref p 'text))]
                [else (emit-expr (hash-ref p 'expr) depth)]))
            parts))
     (format "(s ~a)" (string-join rendered " "))]))

(define (emit-mstring parts depth)
  (define text-parts
    (map (λ (p)
           (case (kind-of p)
             [("Literal") (hash-ref p 'text)]
             [else (format "${~a}" (emit-expr (hash-ref p 'expr) depth))]))
         parts))
  (define joined (apply string-append text-parts))
  (define lines (string-split joined "\n"))
  (define trimmed
    (let* ([l (if (and (pair? lines) (equal? (car lines) "")) (cdr lines) lines)]
           [l (if (and (pair? l) (equal? (last l) "")) (drop-right l 1) l)])
      l))
  (cond
    [(null? trimmed) "(ms \"\")"]
    [else
     (format "(ms~a)"
             (apply string-append
                    (map (λ (line) (format " ~s" line)) trimmed)))]))

(define (emit-list-node node depth)
  (define items (hash-ref node 'items))
  (cond
    [(null? items) "(lst)"]
    [(short-list? items)
     (format "(lst ~a)"
             (string-join (map (λ (i) (emit-expr i depth)) items) " "))]
    [else
     (define ind (indent (+ depth 1)))
     (format "(lst\n~a~a)"
             (string-join (map (λ (i) (string-append ind (emit-expr i (+ depth 1)))) items) "\n")
             (if (null? items) "" ""))]))

(define (short-list? items)
  (and (<= (length items) 4)
       (andmap scalar-ish? items)))

(define (scalar-ish? n)
  (case (kind-of n)
    [("Integer" "Float" "Ident" "Path") #t]
    [("Str") (let ([ps (hash-ref n 'parts)])
               (and (= (length ps) 1)
                    (equal? (kind-of (car ps)) "Literal")))]
    [else #f]))

(define (emit-attrset node depth)
  (define entries (hash-ref node 'entries))
  (define rec? (hash-ref node 'recursive #f))
  (define ctor (if rec? "rec-att" "att"))
  (cond
    [(null? entries)
     (format "(~a)" ctor)]
    [(short-attrset? entries)
     (format "(~a ~a)" ctor (emit-entries-inline entries (+ depth 1)))]
    [else
     (define ind (indent (+ depth 1)))
     (format "(~a\n~a)" ctor
             (string-join
              (map (λ (e)
                     (define before (flush-comments-before! (entry-start e) (+ depth 1)))
                     (string-append before
                                    (or (and (zero? (string-length before)) ind) "")
                                    (emit-entry e (+ depth 1))))
                   entries)
              "\n"))]))

(define (entry-start e)
  (case (kind-of e)
    [("AttrpathValue") (node-start (hash-ref e 'value))]
    [else #f]))

(define (short-attrset? entries)
  (and (<= (length entries) 1)
       (andmap (λ (e)
                 (and (equal? (kind-of e) "AttrpathValue")
                      (scalar-ish? (hash-ref e 'value))))
               entries)))

(define (emit-entries entries depth)
  (define ind (indent depth))
  (string-join
   (map (λ (e) (string-append ind (emit-entry e depth))) entries)
   "\n"))

(define (emit-entries-inline entries depth)
  (string-join (map (λ (e) (emit-entry e depth)) entries) " "))

(define (emit-entry entry depth)
  (case (kind-of entry)
    [("AttrpathValue")
     (define path (hash-ref entry 'path))
     (define value (hash-ref entry 'value))
     (define path-str (emit-attrpath path))
     (format "(~a ~a)" path-str (emit-expr value depth))]
    [("Inherit")
     (define from (hash-ref entry 'from #f))
     (define names (hash-ref entry 'names))
     (cond
       [(or (not from) (eq? from (json-null)))
        (format "(inh ~a)" (string-join (map ->str names) " "))]
       [else
        (format "(inh-from ~a ~a)"
                (emit-expr from depth)
                (string-join (map ->str names) " "))])]))

(define (emit-attrpath path)
  (define joined (string-join (map ->str path) "."))
  (cond
    [(or (regexp-match? #rx"\"" joined)
         (regexp-match? #rx"\\$\\{" joined))
     (format "~s" joined)]
    [else joined]))

(define (emit-binop node depth)
  (define op (hash-ref node 'op))
  (define lhs (hash-ref node 'lhs))
  (define rhs (hash-ref node 'rhs))
  (define form
    (case op
      [("+")  "+"]    [("-")  "-"]    [("*") "*"]    [("/") "/"]
      [("==") "=="]   [("!=") "!="]
      [("<")  "<"]    [("<=") "<="]   [(">") ">"]    [(">=") ">="]
      [("&&") "and"]  [("||") "or"]   [("->") "impl"]
      [("//") "merge"][("++") "concat-list"]
      [else op]))
  (format "(~a ~a ~a)" form (emit-expr lhs depth) (emit-expr rhs depth)))

(define (emit-unop node depth)
  (define op (hash-ref node 'op))
  (define e (hash-ref node 'expr))
  (case op
    [("!") (format "(not ~a)" (emit-expr e depth))]
    [("-") (format "(neg ~a)" (emit-expr e depth))]
    [else  (format "(~a ~a)" op (emit-expr e depth))]))

(define (emit-apply node depth)
  (define-values (fn args) (flatten-apply node))
  (format "(call ~a~a)"
          (emit-expr fn depth)
          (apply string-append
                 (map (λ (a) (string-append " " (emit-expr a depth))) args))))

(define (flatten-apply node)
  (let loop ([n node] [acc '()])
    (case (kind-of n)
      [("Apply")
       (loop (hash-ref n 'fn) (cons (hash-ref n 'arg) acc))]
      [else (values n acc)])))

(define (emit-select node depth)
  (define expr (hash-ref node 'expr))
  (define attrpath (hash-ref node 'attrpath))
  (define default (hash-ref node 'default #f))
  (cond
    [(or (not default) (eq? default (json-null)))
     (cond
       [(equal? (kind-of expr) "Ident")
        (format "~a.~a" (hash-ref expr 'name) (emit-attrpath attrpath))]
       [else
        (format "(get ~a '~a)" (emit-expr expr depth) (emit-attrpath attrpath))])]
    [else
     (format "(get-or ~a '~a ~a)"
             (emit-expr expr depth)
             (emit-attrpath attrpath)
             (emit-expr default depth))]))

(define (emit-has-attr node depth)
  (define expr (hash-ref node 'expr))
  (define path (hash-ref node 'attrpath))
  (format "(has ~a '~a)" (emit-expr expr depth) (emit-attrpath path)))

(define (emit-lambda node depth)
  (define param (hash-ref node 'param))
  (define body (hash-ref node 'body))
  (case (kind-of param)
    [("Ident")
     (format "(fn ~a~n~a~a)"
             (hash-ref param 'name)
             (indent (+ depth 1))
             (emit-expr body (+ depth 1)))]
    [("Pattern")
     (define entries (hash-ref param 'entries))
     (define ellipsis (hash-ref param 'ellipsis #f))
     (define bind
       (let ([b (hash-ref param 'bind #f)])
         (and b (not (eq? b (json-null))) b)))
     (define entry-str
       (string-join
        (map (λ (e)
               (define name (hash-ref e 'name))
               (define default (hash-ref e 'default #f))
               (cond
                 [(or (not default) (eq? default (json-null))) name]
                 [else (format "(~a ~a)" name (emit-expr default (+ depth 1)))]))
             entries)
        " "))
     (define ctor
       (cond
         [(and bind ellipsis) "fn-set@-rest"]
         [bind "fn-set@"]
         [ellipsis "fn-set-rest"]
         [else "fn-set"]))
     (cond
       [bind
        (format "(~a ~a (~a)~n~a~a)"
                ctor bind entry-str
                (indent (+ depth 1))
                (emit-expr body (+ depth 1)))]
       [else
        (format "(~a (~a)~n~a~a)"
                ctor entry-str
                (indent (+ depth 1))
                (emit-expr body (+ depth 1)))])]))

(define (emit-letin node depth)
  (define entries (hash-ref node 'entries))
  (define body (hash-ref node 'body))
  (define ind (indent (+ depth 1)))
  (define bindings
    (string-join
     (filter-map
      (λ (e)
        (cond
          [(equal? (kind-of e) "AttrpathValue")
           (define path (hash-ref e 'path))
           (define val (hash-ref e 'value))
           (cond
             [(= (length path) 1)
              (format "[~a ~a]" (car path) (emit-expr val (+ depth 2)))]
             [else
              (format "[~a ~a]" (string-join path ".") (emit-expr val (+ depth 2)))])]
          [else #f]))
      entries)
     " "))
  (format "(let-in (~a)~n~a~a)" bindings ind (emit-expr body (+ depth 1))))

(define (emit-with node depth)
  (format "(with-do ~a ~a)"
          (emit-expr (hash-ref node 'ns) depth)
          (emit-expr (hash-ref node 'body) depth)))

(define (emit-ifelse node depth)
  (format "(if-then ~a ~a ~a)"
          (emit-expr (hash-ref node 'cond) depth)
          (emit-expr (hash-ref node 'then) depth)
          (emit-expr (hash-ref node 'else) depth)))

(define (emit-assert node depth)
  (format "(assert-do ~a ~a)"
          (emit-expr (hash-ref node 'cond) depth)
          (emit-expr (hash-ref node 'body) depth)))

;; ---------- main ----------

(define (main)
  (define WRAP-RAW-FILE? (make-parameter #t))
  (define LANG-LINE? (make-parameter #t))

  (define files-arg
    (command-line
     #:program "nisp import"
     #:once-each
     [("--no-wrap") "Don't wrap output in (raw-file ...). Just emit the bare expression."
      (WRAP-RAW-FILE? #f)]
     [("--no-lang") "Don't prepend the #lang nisp line."
      (LANG-LINE? #f)]
     #:args files
     files))

  (define parser-bin (locate-parser-bin))

  (define (process-source source-text)
    (define result (run-parser parser-bin source-text))
    (define ast (hash-ref result 'ast))
    (define errors (hash-ref result 'errors '()))
    (define comments
      (sort (hash-ref result 'comments '()) <
            #:key comment-start))
    (when (not (null? errors))
      (eprintf "nisp import: ~a parse error(s):\n" (length errors))
      (for ([e (in-list errors)]) (eprintf "  ~a\n" e)))
    (parameterize ([PENDING-COMMENTS comments])
      (define root-start (or (node-start ast) +inf.0))
      (define lead (flush-comments-before! root-start 0))
      (define body (emit-expr ast 1))
      (define trail (flush-remaining-comments 0))
      (define wrapped
        (cond [(WRAP-RAW-FILE?) (format "(raw-file~n  ~a)~n" body)]
              [else (string-append body "\n")]))
      (define final
        (cond [(LANG-LINE?) (string-append "#lang nisp\n\n" lead wrapped trail)]
              [else (string-append lead wrapped trail)]))
      (display final)))

  (cond
    [(null? files-arg)
     (process-source (port->string (current-input-port)))]
    [else
     (for ([f (in-list files-arg)])
       (process-source (call-with-input-file f port->string)))]))
