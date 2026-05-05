#lang racket/base

;; nisp/edit — programmatic edits to nisp source files.
;;
;; Source-text-preserving — we use Racket's read-syntax to locate AST
;; nodes, then do text-level surgery using their byte positions. This
;; keeps the user's hand-formatted source (comments, whitespace,
;; line breaks) intact except in the edited region.
;;
;; Ops:
;;   (edit-set src path value-text)   — replace `(set 'PATH ...)` value
;;   (edit-unset src path)            — remove the `(set 'PATH ...)` form
;;   (edit-enable src path)           — add/keep `(enable PATH)` line
;;   (edit-disable src path)          — remove `path` from `(enable …)` lists
;;
;; Each takes a source string and returns a modified string. Existence-
;; checks and validation are the caller's responsibility — chain through
;; firn-validate to verify.

(require racket/string
         racket/port
         racket/list)

(provide edit-set
         edit-unset
         edit-enable-add
         edit-enable-remove
         find-set-form-positions)

;; ---------- locate (set 'PATH …) and (set PATH …) forms ----------

(define (count-newlines s)
  (for/sum ([c (in-string s)] #:when (char=? c #\newline)) 1))

;; Walk every top-level form in `src` (a #lang nisp source string),
;; calling `visit` on each syntax node. Strips the #lang line first
;; (read-syntax can't cross #lang) and pads with whitespace so byte
;; positions in the resulting syntax objects match positions in `src`.
(define (walk-source-forms src visit)
  (define-values (lang-prefix rest)
    (let ([m (regexp-match-positions #rx"^#lang [^\n]*\n" src)])
      (cond [m (values (substring src 0 (cdr (car m)))
                       (substring src (cdr (car m))))]
            [else (values "" src)])))
  (define padded
    (string-append (make-string (count-newlines lang-prefix) #\newline)
                   (make-string (- (string-length lang-prefix)
                                   (count-newlines lang-prefix))
                                #\space)
                   rest))
  (define port (open-input-string padded))
  (port-count-lines! port)
  (with-handlers ([exn:fail? (λ (_) (void))])
    (let loop ()
      (define stx (read-syntax 'src port))
      (unless (eof-object? stx)
        (walk stx visit)
        (loop)))))

;; Returns a list of (start . end) byte positions for every `(set …)`
;; form in src whose first arg is a quoted symbol matching exactly the
;; given path string.
(define (find-set-form-positions src target-path)
  (define out '())
  (walk-source-forms src
    (λ (s)
      (define matched-pos (set-form-matches? s target-path))
      (when matched-pos
        (set! out (cons matched-pos out)))))
  (reverse out))

;; Returns a list of (start . end) positions for ALL `(set …)` forms in
;; src, regardless of path. Used by edit-set to position new forms next
;; to existing (set …) calls.
(define (find-all-set-form-positions src)
  (define out '())
  (walk-source-forms src
    (λ (s)
      (define lst (syntax->list s))
      (when (and lst (pair? lst)
                 (identifier? (car lst))
                 (eq? (syntax->datum (car lst)) 'set))
        (define start (sub1 (syntax-position s)))
        (define span (syntax-span s))
        (set! out (cons (cons start (+ start span)) out)))))
  (reverse out))

(define (walk stx visit)
  (visit stx)
  (define lst (syntax->list stx))
  (when lst (for-each (λ (s) (walk s visit)) lst)))

(define (set-form-matches? stx target-path)
  ;; Returns (cons start end) of the form if it matches `(set 'TARGET …)`,
  ;; #f otherwise. Both `(set 'foo.bar val)` and `(set foo.bar val)`
  ;; (bare path via #%top) match.
  (define lst (syntax->list stx))
  (cond
    [(or (not lst) (null? lst)) #f]
    [else
     (define head (and (identifier? (car lst))
                       (syntax->datum (car lst))))
     (cond
       [(and (eq? head 'set)
             (>= (length lst) 2)
             (path-arg-matches? (cadr lst) target-path))
        (define start (sub1 (syntax-position stx)))   ; 1-indexed → 0
        (define span (syntax-span stx))
        (cons start (+ start span))]
       [else #f])]))

(define (path-arg-matches? arg target)
  ;; `arg` is the syntax of the path argument (after `set`).
  ;; Matches both:
  ;;   'foo.bar         → quote form, literal symbol
  ;;   foo.bar          → bare identifier (uses #%top)
  (define datum (syntax->datum arg))
  (cond
    [(and (pair? datum) (eq? (car datum) 'quote)
          (symbol? (cadr datum)))
     (equal? (symbol->string (cadr datum)) target)]
    [(symbol? datum)
     (equal? (symbol->string datum) target)]
    [else #f]))

;; ---------- edit ops ----------

(define (edit-set src path value-text)
  ;; If `(set 'path …)` exists, replace its entire form. Otherwise insert
  ;; a new one — preferring "after the last existing (set …)" so it lands
  ;; at the right scope inside config-body / host-file bodies.
  (define matches (find-set-form-positions src path))
  (define new-form (format "(set '~a ~a)" path value-text))
  (cond
    [(null? matches)
     (insert-set-after-last-set src new-form)]
    [else
     (define-values (start end) (values (caar (reverse matches))
                                        (cdar (reverse matches))))
     (string-append (substring src 0 start)
                    new-form
                    (substring src end))]))

(define (insert-set-after-last-set src new-form)
  ;; Find the last `(set …)` form (any path), insert new-form on the next
  ;; line with matching indentation. Falls back to "before final close"
  ;; if there's no existing (set …).
  (define all-sets (find-all-set-form-positions src))
  (cond
    [(null? all-sets) (insert-set-before-final-close src new-form)]
    [else
     (define last-end (cdar (reverse all-sets)))
     ;; Find the indentation of the last set's line.
     (define last-line-start
       (let loop ([i (sub1 (caar (reverse all-sets)))])
         (cond
           [(or (negative? i) (char=? (string-ref src i) #\newline)) (+ i 1)]
           [else (loop (- i 1))])))
     (define indent-end
       (let loop ([i last-line-start])
         (cond
           [(>= i (string-length src)) i]
           [(char-whitespace? (string-ref src i))
            (cond [(char=? (string-ref src i) #\newline) i]
                  [else (loop (+ i 1))])]
           [else i])))
     (define indent (substring src last-line-start indent-end))
     (string-append (substring src 0 last-end)
                    "\n" indent new-form
                    (substring src last-end))]))

(define (edit-unset src path)
  ;; Remove every `(set 'path …)` form. Returns src unchanged if none
  ;; match.
  (define matches (find-set-form-positions src path))
  (cond
    [(null? matches) src]
    [else
     ;; Remove from latest position to earliest so offsets stay valid.
     (define sorted (sort matches > #:key car))
     (for/fold ([acc src]) ([m (in-list sorted)])
       (define start (car m))
       (define end (cdr m))
       ;; Also consume trailing whitespace/newline so we don't leave a blank line.
       (define real-end
         (let loop ([i end])
           (cond
             [(>= i (string-length acc)) i]
             [(char=? (string-ref acc i) #\newline) (+ i 1)]
             [(char-whitespace? (string-ref acc i)) (loop (+ i 1))]
             [else i])))
       ;; And consume leading indentation on the start line.
       (define real-start
         (let loop ([i start])
           (cond
             [(zero? i) i]
             [(char=? (string-ref acc (- i 1)) #\newline) i]
             [(char-whitespace? (string-ref acc (- i 1))) (loop (- i 1))]
             [else i])))
       (string-append (substring acc 0 real-start)
                      (substring acc real-end)))]))

(define (insert-set-before-final-close src new-form)
  ;; Find the depth-0 closing paren of the outermost form and insert
  ;; `new-form` on its own line just before it, indented to match the
  ;; existing forms. Strategy:
  ;;   - Walk backwards from close-pos through any whitespace
  ;;   - Find the indent of the previous non-whitespace line
  ;;   - Insert "\n<indent><new-form>" before the close
  (define len (string-length src))
  (define close-pos (find-final-close-paren src))
  (cond
    [(not close-pos) (string-append src "\n" new-form "\n")]
    [else
     (define ws-start
       (let loop ([i close-pos])
         (cond
           [(zero? i) i]
           [(char-whitespace? (string-ref src (- i 1))) (loop (- i 1))]
           [else i])))
     (define prev-indent
       (let* ([line-start
               (let loop ([i (- ws-start 1)])
                 (cond
                   [(or (negative? i) (char=? (string-ref src i) #\newline)) (+ i 1)]
                   [else (loop (- i 1))]))]
              [line-end
               (let loop ([i line-start])
                 (cond
                   [(>= i len) i]
                   [(or (char=? (string-ref src i) #\newline)
                        (not (char-whitespace? (string-ref src i)))) i]
                   [else (loop (+ i 1))]))])
         (substring src line-start line-end)))
     (string-append (substring src 0 ws-start)
                    "\n" prev-indent new-form
                    (substring src ws-start))]))

;; ============================================================================
;; (enable …) form manipulation
;; ============================================================================
;;
;; `(enable a b c)` is nisp's variadic-args form for toggling option paths
;; on. enable-add appends a path to an existing form (or inserts a new one
;; if none exists). enable-remove drops a path; if it was the only arg,
;; the form is deleted entirely. Idempotent: enable-add a path that's
;; already present is a no-op; same for enable-remove on an absent path.

;; Returns a list of `(start end args)` for every `(enable …)` form.
;; `start`/`end` are byte offsets; `args` is a list of (arg-text start end)
;; tuples for the path arguments.
(define (find-enable-forms src)
  (define out '())
  (walk-source-forms src
    (λ (s)
      (define lst (syntax->list s))
      (when (and lst (pair? lst)
                 (identifier? (car lst))
                 (eq? (syntax->datum (car lst)) 'enable))
        (define start (sub1 (syntax-position s)))
        (define span (syntax-span s))
        (define args
          (for/list ([arg (in-list (cdr lst))])
            (define arg-start (sub1 (syntax-position arg)))
            (define arg-end (+ arg-start (syntax-span arg)))
            (define text (substring src arg-start arg-end))
            (list text arg-start arg-end)))
        (set! out (cons (list start (+ start span) args) out)))))
  (reverse out))

(define (path-arg-text->path text)
  ;; Both `'foo.bar` and `foo.bar` (bare) are valid; strip leading quote.
  (regexp-replace #rx"^'" text ""))

(define (edit-enable-add src path)
  ;; If `path` already appears in any `(enable …)` form, no-op.
  ;; Otherwise: append `path` to the LAST existing `(enable …)` form,
  ;; or insert a new `(enable path)` form if none exist.
  (define forms (find-enable-forms src))
  (cond
    [(any-form-contains-path? forms path) src]
    [(null? forms)
     (insert-enable-form src path)]
    [else
     ;; Append to the LAST (enable …) form, before its closing paren.
     ;; Detect formatting style: if the existing args span multiple lines,
     ;; insert with the same indentation (matched to the last arg's column);
     ;; otherwise inline with a single space.
     (define target (last forms))
     (define-values (start end args) (apply values target))
     (define close-pos (sub1 end))
     (define form-text (substring src start end))
     (define separator
       (cond
         [(null? args) " "]
         [(not (regexp-match? #rx"\n" form-text))
          ;; Single-line form → inline append.
          " "]
         [else
          ;; Multi-line form — match the last arg's column.
          (define last-arg-start (cadr (last args)))
          (define line-start
            (let loop ([i (sub1 last-arg-start)])
              (cond
                [(or (negative? i) (char=? (string-ref src i) #\newline)) (+ i 1)]
                [else (loop (- i 1))])))
          (define indent (substring src line-start last-arg-start))
          (string-append "\n" indent)]))
     (string-append (substring src 0 close-pos)
                    separator path
                    (substring src close-pos))]))

(define (edit-enable-remove src path)
  ;; Find any `(enable …)` form that has `path` (or `'path`) as an arg.
  ;; Remove the arg. If the form's only arg was `path`, remove the
  ;; entire form. No-op if `path` not present anywhere.
  (define forms (find-enable-forms src))
  (define matching
    (for/list ([f (in-list forms)]
               #:when (form-contains-path? f path))
      f))
  (cond
    [(null? matching) src]
    [else
     ;; Process from latest position to earliest so offsets stay valid.
     (define sorted (sort matching > #:key car))
     (for/fold ([acc src]) ([f (in-list sorted)])
       (define-values (start end args) (apply values f))
       (define remaining
         (filter (λ (a) (not (path-matches? (car a) path))) args))
       (cond
         [(null? remaining)
          ;; Form becomes empty — remove it (with leading whitespace cleanup).
          (define real-start
            (let loop ([i start])
              (cond
                [(zero? i) i]
                [(char=? (string-ref acc (- i 1)) #\newline) i]
                [(char-whitespace? (string-ref acc (- i 1))) (loop (- i 1))]
                [else i])))
          (define real-end
            (let loop ([i end])
              (cond
                [(>= i (string-length acc)) i]
                [(char=? (string-ref acc i) #\newline) (+ i 1)]
                [(char-whitespace? (string-ref acc i)) (loop (+ i 1))]
                [else i])))
          (string-append (substring acc 0 real-start)
                         (substring acc real-end))]
         [else
          ;; Surgical removal: cut just the matching arg + its preceding
          ;; whitespace. This preserves the original formatting (multi-line
          ;; vs single-line) of the surrounding form.
          (define matching-arg
            (findf (λ (a) (path-matches? (car a) path)) args))
          (define-values (_text arg-start arg-end) (apply values matching-arg))
          ;; Walk back through whitespace to consume the preceding gap.
          (define cut-start
            (let loop ([i arg-start])
              (cond
                [(<= i (+ start 8))   ; "(enable " is 8 chars; don't cross
                 i]
                [(char-whitespace? (string-ref acc (- i 1))) (loop (- i 1))]
                [else i])))
          ;; If we ended up consuming back to "(enable" itself, leave one
          ;; space so the result is "(enable rest…)" not "(enablerest…)".
          (define final-cut-start
            (cond [(and (>= cut-start (+ start 8))
                        (char-whitespace? (string-ref acc (sub1 cut-start))))
                   cut-start]
                  [else (+ cut-start 0)]))
          ;; Special case: removing the FIRST arg leaves leading whitespace
          ;; after "(enable" — cut from arg-end forward instead.
          (define is-first-arg?
            (equal? matching-arg (car args)))
          (cond
            [is-first-arg?
             ;; Cut "(enable" + (any whitespace) + arg + (whitespace
             ;; up to next arg) → "(enable" + (one space) + next-arg-start
             (define after-arg-start
               (let loop ([i arg-end])
                 (cond
                   [(>= i (string-length acc)) i]
                   [(char-whitespace? (string-ref acc i)) (loop (+ i 1))]
                   [else i])))
             (string-append (substring acc 0 arg-start)
                            (substring acc after-arg-start))]
            [else
             (string-append (substring acc 0 final-cut-start)
                            (substring acc arg-end))])]))]))

(define (any-form-contains-path? forms path)
  (for/or ([f (in-list forms)]) (form-contains-path? f path)))

(define (form-contains-path? form path)
  (define args (caddr form))
  (for/or ([a (in-list args)]) (path-matches? (car a) path)))

(define (path-matches? arg-text path)
  (equal? (path-arg-text->path arg-text) path))

(define (insert-enable-form src path)
  ;; Insert (enable PATH) on its own line. Strategy mirrors
  ;; insert-set-after-last-set: find the last existing top-level form
  ;; and insert after it; fall back to before the file's outermost close.
  (define matches (find-all-set-form-positions src))
  (define enable-form (format "(enable ~a)" path))
  (cond
    [(pair? matches)
     ;; Insert after the last set form.
     (define last-end (cdar (reverse matches)))
     (define last-line-start
       (let loop ([i (sub1 (caar (reverse matches)))])
         (cond
           [(or (negative? i) (char=? (string-ref src i) #\newline)) (+ i 1)]
           [else (loop (- i 1))])))
     (define indent-end
       (let loop ([i last-line-start])
         (cond
           [(>= i (string-length src)) i]
           [(char-whitespace? (string-ref src i))
            (cond [(char=? (string-ref src i) #\newline) i]
                  [else (loop (+ i 1))])]
           [else i])))
     (define indent (substring src last-line-start indent-end))
     (string-append (substring src 0 last-end)
                    "\n" indent enable-form
                    (substring src last-end))]
    [else
     (insert-set-before-final-close src enable-form)]))

(define (find-final-close-paren src)
  ;; Walk the source tracking paren depth (skipping strings/comments)
  ;; and return the position of the depth-0 close that ends the file's
  ;; last top-level form.
  (define len (string-length src))
  (define result #f)
  (let loop ([i 0] [depth 0] [in-string? #f] [in-line-comment? #f])
    (cond
      [(>= i len) result]
      [else
       (define c (string-ref src i))
       (cond
         [in-line-comment?
          (cond [(char=? c #\newline) (loop (+ i 1) depth in-string? #f)]
                [else (loop (+ i 1) depth in-string? #t)])]
         [in-string?
          (cond [(and (char=? c #\\) (< (+ i 1) len))
                 (loop (+ i 2) depth in-string? #f)]
                [(char=? c #\") (loop (+ i 1) depth #f #f)]
                [else (loop (+ i 1) depth in-string? #f)])]
         [(char=? c #\;) (loop (+ i 1) depth in-string? #t)]
         [(char=? c #\") (loop (+ i 1) depth #t #f)]
         [(char=? c #\() (loop (+ i 1) (+ depth 1) #f #f)]
         [(char=? c #\))
          (cond [(= depth 1)
                 (set! result i)
                 (loop (+ i 1) 0 #f #f)]
                [else (loop (+ i 1) (- depth 1) #f #f)])]
         [else (loop (+ i 1) depth in-string? #f)])])))
