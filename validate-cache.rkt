#lang racket/base

;; nisp/validate-cache — schema loading + lazy submodule expansion.
;;
;; Shared by cli/validate.rkt, lsp.rkt, cli/schema.rkt. Each was
;; reimplementing this layer; consolidating here.
;;
;; Responsibilities:
;;   - Load .nisp-cache/schema.json
;;   - Load .nisp-cache/schema-submodules.json (flake.lock-keyed)
;;   - On-demand submodule expansion via batched `nix eval`
;;   - The conventional "in-submodule fallback" + wildcard `<name>`
;;     matching for paths past `attrsOf submodule` boundaries
;;
;; The validator's core checks (path-walking, type matching, did-you-mean)
;; live in nisp/validate. This module owns IO + Nix integration.

(require racket/file
         racket/list
         racket/string
         racket/port
         racket/path
         racket/system
         file/sha1
         json
         (only-in nisp/validate
                  walk-syntax
                  extract-from-form
                  path-ref-path
                  find-similar-strs))

(provide
 ;; Cache config
 (struct-out cache-config)
 default-cache-config

 ;; Schema state
 make-schema-state
 schema-state?
 schema-state-table
 schema-state-sub-cache
 load-schema!

 ;; Lookup
 schema-lookup
 schema-lookup/wildcard
 namespace-known?

 ;; Path classification
 in-submodule?
 find-submodule-ancestor
 has-interpolation?

 ;; Lazy expansion
 collect-paths-in-file
 discover-and-expand!

 ;; Constants
 SUBMODULE-TYPES
 MODULE-STRUCTURAL-KEYS
 WILDCARD)

;; ============================================================================
;; Config
;; ============================================================================

(struct cache-config (flake-root cache-dir target hm-roots)
  #:transparent)

(define (default-cache-config flake-root [target #f] [hm-roots '()])
  (cache-config flake-root
                (build-path flake-root ".nisp-cache")
                (or target
                    (string-append "nixosConfigurations."
                                   (or (getenv "FIRN_HOST") "default")
                                   ".options"))
                hm-roots))

(define EXTRACTOR-VERSION 1)

;; ============================================================================
;; Schema state
;; ============================================================================

(struct schema-state (table sub-cache config failed-prefixes namespace-set)
  #:mutable #:transparent)

(define (make-schema-state config)
  (schema-state (make-hash) (make-hash) config (make-hash) (make-hash)))

(define SUBMODULE-TYPES
  '("attrsOf" "submodule" "lazyAttrsOf" "listOf" "oneOf" "either"
    "functionTo" "unspecified"))

(define MODULE-STRUCTURAL-KEYS
  '("config" "options" "imports" "_module" "_file"))

(define WILDCARD "<name>")

;; ============================================================================
;; Cache file IO
;; ============================================================================

(define (schema-path c)     (build-path (cache-config-cache-dir c) "schema.json"))
(define (sub-cache-path c)  (build-path (cache-config-cache-dir c) "schema-submodules.json"))

(define (cache-key c)
  (define lock (build-path (cache-config-flake-root c) "flake.lock"))
  (define lock-bytes (if (file-exists? lock) (file->bytes lock) #""))
  (string-append (sha1 (open-input-bytes lock-bytes))
                 ":v" (number->string EXTRACTOR-VERSION)
                 ":" (cache-config-target c)))

(define (load-base-schema! state)
  (define c (schema-state-config state))
  (define p (schema-path c))
  (when (file-exists? p)
    (for ([e (in-list (call-with-input-file p read-json))])
      (hash-set! (schema-state-table state) (hash-ref e 'p) e)))
  ;; Build namespace prefix set for namespace-known? checks.
  (for ([p (in-hash-keys (schema-state-table state))])
    (define parts (string-split p "."))
    (let loop ([acc '()] [parts parts])
      (cond
        [(null? (cdr parts)) (void)]
        [else
         (define new-acc (cons (car parts) acc))
         (hash-set! (schema-state-namespace-set state)
                    (string-join (reverse new-acc) ".") #t)
         (loop new-acc (cdr parts))]))))

(define (load-sub-cache! state)
  (define c (schema-state-config state))
  (define p (sub-cache-path c))
  (when (file-exists? p)
    (with-handlers ([exn:fail? void])
      (define data (call-with-input-file p read-json))
      (when (equal? (hash-ref data 'key #f) (cache-key c))
        (for ([(k v) (in-hash (hash-ref data 'submodules (hash)))])
          (define key (symbol->string k))
          (hash-set! (schema-state-sub-cache state) key v)
          ;; Fold cached entries into the main table.
          (for ([e (in-list v)])
            (hash-set! (schema-state-table state) (hash-ref e 'p) e)))))))

(define (load-schema! state)
  (load-base-schema! state)
  (load-sub-cache! state))

(define (save-sub-cache! state)
  (define c (schema-state-config state))
  (unless (directory-exists? (cache-config-cache-dir c))
    (make-directory* (cache-config-cache-dir c)))
  (define data
    (hash 'key (cache-key c)
          'submodules
          (for/hash ([(k v) (in-hash (schema-state-sub-cache state))])
            (values (string->symbol k) v))))
  (call-with-output-file (sub-cache-path c) #:exists 'replace
    (λ (out) (write-json data out))))

;; ============================================================================
;; Lookup
;; ============================================================================

(define (schema-lookup state path)
  (hash-ref (schema-state-table state) path #f))

(define (namespace-known? state path)
  (hash-has-key? (schema-state-namespace-set state) path))

(define (wildcard-lookup state path)
  (define parts (string-split path "."))
  (let try-positions ([i 0])
    (cond
      [(>= i (length parts)) #f]
      [else
       (define try-parts
         (append (take parts i) (list WILDCARD) (drop parts (+ i 1))))
       (define key (string-join try-parts "."))
       (cond
         [(schema-lookup state key) => (λ (e) e)]
         [else (try-positions (+ i 1))])])))

(define (schema-lookup/wildcard state path)
  (or (schema-lookup state path)
      (wildcard-lookup state path)))

(define (has-interpolation? path)
  (regexp-match? #rx"\\$\\{" path))

;; ============================================================================
;; Path classification
;; ============================================================================

(define (find-submodule-ancestor state path)
  ;; Returns (cons prefix kind) — kind is 'plain or 'attrs — or #f.
  (let loop ([parts (string-split path ".")])
    (cond
      [(null? parts) #f]
      [(null? (cdr parts)) #f]
      [else
       (define prefix-parts (drop-right parts 1))
       (define prefix (string-join prefix-parts "."))
       (define entry (schema-lookup state prefix))
       (cond
         [(and entry (equal? (hash-ref entry 't #f) "submodule"))
          (cons prefix 'plain)]
         [(and entry (member (hash-ref entry 't #f) '("attrsOf" "lazyAttrsOf"))
               (let ([i (hash-ref entry 'inner #f)])
                 (and i (equal? (hash-ref i 't #f) "submodule"))))
          (cons prefix 'attrs)]
         [else (loop prefix-parts)])])))

(define (in-submodule? state path)
  ;; Walk up. If we hit a submodule-typed ancestor that was successfully
  ;; expanded (cache has non-empty entries for it), DON'T accept the
  ;; path as a submodule fallback — it's a real typo. Otherwise fall
  ;; back to the heuristic.
  ;;
  ;; Exception: if path is exactly one segment deeper than an attrsOf/lazyAttrsOf
  ;; ancestor, it's a key assignment (e.g. systemd.services.myService) and is
  ;; always valid — the key is user-defined, not schema-defined.
  (let loop ([parts (string-split path ".")])
    (cond
      [(null? parts) #f]
      [(null? (cdr parts)) #f]
      [else
       (define prefix-parts (drop-right parts 1))
       (define prefix (string-join prefix-parts "."))
       (define entry (schema-lookup state prefix))
       (define t (and entry (hash-ref entry 't #f)))
       (cond
         [(and t (member t '("attrsOf" "lazyAttrsOf")))
          #t]
         [(and t (member t SUBMODULE-TYPES))
          (define cached (hash-ref (schema-state-sub-cache state) prefix #f))
          (cond
            [(and cached (not (null? cached))) #f]
            [else #t])]
         [else (loop prefix-parts)])])))

;; ============================================================================
;; Lazy submodule expansion
;; ============================================================================

(define (collect-paths-in-file f)
  (define raw (call-with-input-file f port->string))
  (define-values (lang-prefix rest)
    (let ([m (regexp-match-positions #rx"^#lang [^\n]*\n" raw)])
      (cond [m (values (substring raw 0 (cdr (car m)))
                       (substring raw (cdr (car m))))]
            [else (values "" raw)])))
  (define padded
    (string-append (make-string (count-newlines lang-prefix) #\newline) rest))
  (define port (open-input-string padded))
  (port-count-lines! port)
  (define src (path->string f))
  (define paths '())
  (with-handlers ([exn:fail? (λ (_) (void))])
    (let loop ()
      (define stx (read-syntax src port))
      (unless (eof-object? stx)
        (walk-syntax stx
          (λ (s in-hm?)
            (unless in-hm?
              (for ([pr (in-list (extract-from-form s))])
                (set! paths (cons (path-ref-path pr) paths))))))
        (loop))))
  paths)

(define (count-newlines s)
  (for/sum ([c (in-string s)] #:when (char=? c #\newline)) 1))

(define (build-expansion-expr c prefix-pairs)
  (define pair-strs
    (map (λ (p) (format "{ prefix = ~s; kind = ~s; }"
                        (car p) (symbol->string (cdr p))))
         prefix-pairs))
  (define root-path
    (regexp-replace #rx"/+$" (path->string (cache-config-flake-root c)) ""))
  (string-append "
let
  flake = builtins.getFlake (toString " root-path ");
  opts  = flake." (cache-config-target c) ";
  lib   = flake.inputs.nixpkgs.lib;
  pathToOpt = path:
    let segs = builtins.filter (s: s != \"\") (lib.splitString \".\" path);
    in lib.attrByPath segs null opts;
  describeType = t:
    let
      base = { t = t.name or \"?\"; };
      tryInner = if (t ? nestedTypes) && (t.nestedTypes ? elemType)
        then builtins.tryEval (describeType t.nestedTypes.elemType)
        else { success = false; value = null; };
      withInner = if tryInner.success then base // { inner = tryInner.value; } else base;
      tryEnum = if (t.name or \"\") == \"enum\" && (t ? functor) && (t.functor ? payload) && (t.functor.payload ? values)
        then builtins.tryEval t.functor.payload.values
        else { success = false; value = null; };
      withEnum = if tryEnum.success then withInner // { enum = tryEnum.value; } else withInner;
    in withEnum;
  declarationsOf = o:
    let try = builtins.tryEval (o.declarations or []);
    in if try.success then try.value else [];
  walk = path: o:
    if (o._type or null) == \"option\"
    then [ ({ p = path; declarations = declarationsOf o; } // describeType (o.type or {})) ]
    else if builtins.isAttrs o
    then builtins.concatLists
      (builtins.attrValues
        (builtins.mapAttrs (n: v: walk (\"${path}.${n}\") v) o))
    else [];
  expandPlain = prefix:
    let o = pathToOpt prefix;
        try = builtins.tryEval (
          if o != null && (o.type.name or \"\") == \"submodule\" && (o.type ? getSubOptions)
          then walk prefix (o.type.getSubOptions [])
          else []
        );
    in if try.success then try.value else [];
  expandAttrs = prefix:
    let o = pathToOpt prefix;
        try = builtins.tryEval (
          if o != null
             && builtins.elem (o.type.name or \"\") [\"attrsOf\" \"lazyAttrsOf\"]
             && (o.type.nestedTypes.elemType.name or \"\") == \"submodule\"
             && (o.type.nestedTypes.elemType ? getSubOptions)
          then walk \"" "${prefix}." WILDCARD "\" (o.type.nestedTypes.elemType.getSubOptions [])
          else []
        );
    in if try.success then try.value else [];
  expand = pp:
    if pp.kind == \"plain\" then expandPlain pp.prefix else expandAttrs pp.prefix;
in
  builtins.listToAttrs (map (pp: { name = pp.prefix; value = expand pp; }) [
    " (string-join pair-strs "\n    ") "
  ])
"))

(define (run-nix-eval expr)
  (define out (open-output-string))
  (define err (open-output-string))
  (define ok?
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (system* (find-executable-path "nix")
               "eval" "--json" "--impure" "--expr" expr)))
  (cond
    [ok?
     (with-handlers ([exn:fail? (λ (_) #f)])
       (read-json (open-input-string (get-output-string out))))]
    [else
     (eprintf "nisp: nix eval failed:\n~a\n" (get-output-string err))
     #f]))

(define (expand-submodule-prefixes! state prefix-pairs [progress-port #f])
  (cond
    [(null? prefix-pairs) (hash)]
    [else
     (when progress-port
       (fprintf progress-port "expanding ~a submodule(s) for first-time use...\n"
                (length prefix-pairs)))
     (define c (schema-state-config state))
     (define expr (build-expansion-expr c prefix-pairs))
     (define result (run-nix-eval expr))
     (cond
       [(not result)
        (for ([p (in-list prefix-pairs)])
          (hash-set! (schema-state-failed-prefixes state) (car p) #t))
        (hash)]
       [else
        (define parsed (make-hash))
        (for ([(k v) (in-hash result)])
          (define key (symbol->string k))
          (hash-set! parsed key v)
          (cond
            [(or (null? v) (not (list? v)))
             (hash-set! (schema-state-sub-cache state) key '())
             (hash-set! (schema-state-failed-prefixes state) key #t)]
            [else
             (hash-set! (schema-state-sub-cache state) key v)
             (for ([e (in-list v)])
               (hash-set! (schema-state-table state) (hash-ref e 'p) e))]))
        (save-sub-cache! state)
        parsed])]))

(define (discover-and-expand! state files [progress-port #f])
  (let loop ([round 0])
    (cond
      [(>= round 5) (void)]
      [else
       (define needed
         (let ([h (make-hash)])
           (for* ([f (in-list files)]
                  [p (in-list (collect-paths-in-file f))]
                  #:unless (hash-has-key? (schema-state-table state) p))
             (define anc (find-submodule-ancestor state p))
             (when anc
               (define prefix (car anc))
               (define kind (cdr anc))
               (unless (or (hash-has-key? (schema-state-sub-cache state) prefix)
                           (hash-has-key? (schema-state-failed-prefixes state) prefix))
                 (hash-set! h prefix kind))))
           h))
       (cond
         [(zero? (hash-count needed)) (void)]
         [else
          (expand-submodule-prefixes! state
                                      (for/list ([(k v) (in-hash needed)]) (cons k v))
                                      progress-port)
          (loop (+ round 1))])])))
