#lang racket/base

;; nisp extract-schema — dump an options tree (path + type info) into a
;; JSON cache for the validator to consume.
;;
;; Each entry has:
;;   p     - dotted option path
;;   t     - top-level type name ("bool", "str", "listOf", "nullOr", ...)
;;   inner - (optional) recursive {t, inner?, enum?} for parameterized types
;;   enum  - (optional) list of valid values for enum types
;;
;; Usage:
;;   nisp extract-schema [--target <attr-path>] [--out <file>] [--flake <dir>]
;;
;; Defaults:
;;   --target  nixosConfigurations.$(hostname).options
;;   --out     <flake-root>/.nisp-cache/schema.json
;;   --flake   $(git rev-parse --show-toplevel) or .

(require racket/cmdline
         racket/file
         racket/path
         racket/port
         racket/string
         racket/system
         json)

(provide main)

(define NIX-EXPR
  #<<NIX
let
  flake = builtins.getFlake (toString @FLAKE@);
  opts  = flake.@TARGET@;

  describeType = t:
    let
      base = { t = t.name or "?"; };
      tryInner =
        if (t ? nestedTypes) && (t.nestedTypes ? elemType)
        then builtins.tryEval (describeType t.nestedTypes.elemType)
        else { success = false; value = null; };
      withInner =
        if tryInner.success then base // { inner = tryInner.value; } else base;
      tryEnum =
        if (t.name or "") == "enum" && (t ? functor) && (t.functor ? payload) && (t.functor.payload ? values)
        then builtins.tryEval t.functor.payload.values
        else { success = false; value = null; };
      withEnum =
        if tryEnum.success then withInner // { enum = tryEnum.value; } else withInner;
    in withEnum;

  declarationsOf = o:
    let try = builtins.tryEval (o.declarations or []);
    in if try.success then try.value else [];

  walk = path: o:
    if (o._type or null) == "option"
    then [ ({ p = path; declarations = declarationsOf o; } // describeType (o.type or {})) ]
    else if builtins.isAttrs o
    then builtins.concatLists
      (builtins.attrValues
        (builtins.mapAttrs (n: v: walk (if path == "" then n else "${path}.${n}") v) o))
    else [];
in walk "" opts
NIX
)

(define (sh-out . args)
  (define o (open-output-string))
  (parameterize ([current-output-port o]) (apply system* args))
  (string-trim (get-output-string o)))

(define (host-name)
  (let ([h (sh-out (find-executable-path "hostname"))])
    (if (non-empty-string? h) h "default")))

(define (git-toplevel)
  (define git (find-executable-path "git"))
  (cond
    [(not git) #f]
    [else
     (define s (sh-out git "rev-parse" "--show-toplevel"))
     (and (non-empty-string? s) s)]))

(define (main)
  (define TARGET (make-parameter #f))
  (define OUT (make-parameter #f))
  (define FLAKE (make-parameter #f))

  (command-line
   #:program "nisp extract-schema"
   #:once-each
   [("--target") t "nix attr-path to extract (default: nixosConfigurations.<host>.options)"
    (TARGET t)]
   [("--out") o "output file (default: <flake-root>/.nisp-cache/schema.json)"
    (OUT o)]
   [("--flake") f "flake root (default: git toplevel or cwd)"
    (FLAKE f)]
   #:args () (void))

  (define flake-root
    (let* ([raw (or (FLAKE) (git-toplevel)
                    (path->string (current-directory)))]
           [trimmed (regexp-replace #rx"/$" raw "")])
      trimmed))

  (define target
    (or (TARGET)
        (string-append "nixosConfigurations." (host-name) ".options")))

  (define out-path
    (cond
      [(OUT) (OUT)]
      [else (path->string (build-path flake-root ".nisp-cache" "schema.json"))]))

  (make-directory* (or (path-only (string->path out-path)) (current-directory)))

  (printf "nisp extract-schema: extracting ~a from ~a...\n" target flake-root)

  (define expr
    (regexp-replaces NIX-EXPR
                     `((#rx"@FLAKE@"  ,flake-root)
                       (#rx"@TARGET@" ,target))))

  (define nix (find-executable-path "nix"))
  (unless nix
    (eprintf "nisp extract-schema: `nix` not found in PATH.\n")
    (exit 2))

  (define stdout-bytes (open-output-bytes))
  (define stderr-str (open-output-string))
  (define ok?
    (parameterize ([current-output-port stdout-bytes]
                   [current-error-port stderr-str])
      (system* nix "eval" "--json" "--impure" "--expr" expr)))

  (unless ok?
    (eprintf "nisp extract-schema: nix eval failed.\n")
    (define err (get-output-string stderr-str))
    (when (non-empty-string? err) (eprintf "~a\n" err))
    (exit 1))

  (define payload (get-output-bytes stdout-bytes))
  (with-output-to-file out-path #:exists 'replace
    (λ () (write-bytes payload)))

  (define entries (read-json (open-input-bytes payload)))
  (define count (length entries))
  (define size (bytes-length payload))
  (printf "nisp extract-schema: cached ~a option paths (~a bytes) → ~a\n"
          count size out-path))
