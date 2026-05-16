#lang racket/base

;; nisp extract-packages — dump package attr names into a JSON cache
;; for the validator to consume.
;;
;; Evaluates nixpkgs (with overlays from the flake's nixosConfiguration)
;; and extracts top-level attr names for pkgs, unstable, and master sets.
;;
;; Usage:
;;   nisp extract-packages [--flake <dir>] [--host <hostname>] [--system <system>] [--out <file>]

(require racket/cmdline
         racket/file
         racket/path
         racket/port
         racket/string
         racket/system
         file/sha1
         json)

(provide main)

(define NIX-EXPR
  #<<NIX
let
  flake = builtins.getFlake (toString @FLAKE@);
  system = "@SYSTEM@";
  cfg = flake.nixosConfigurations.@HOST@;
  overlays = cfg.config.nixpkgs.overlays or [];
  pkgs = import flake.inputs.nixpkgs { inherit system; config.allowUnfree = true; inherit overlays; };
  unstable = pkgs.unstable or {};
  master = pkgs.master or {};
  safeNames = set: builtins.tryEval (builtins.attrNames set);
in {
  pkgs = (safeNames pkgs).value or [];
  unstable = (safeNames unstable).value or [];
  master = (safeNames master).value or [];
}
NIX
)

(define (sh-out . args)
  (define o (open-output-string))
  (parameterize ([current-output-port o]) (apply system* args))
  (string-trim (get-output-string o)))

(define (host-name)
  (let ([h (sh-out (find-executable-path "hostname"))])
    (if (non-empty-string? h) h "whiterabbit")))

(define (git-toplevel)
  (define git (find-executable-path "git"))
  (cond
    [(not git) #f]
    [else
     (define s (sh-out git "rev-parse" "--show-toplevel"))
     (and (non-empty-string? s) s)]))

(define (cache-key flake-root)
  (define lock (build-path flake-root "flake.lock"))
  (define lock-bytes (if (file-exists? lock) (file->bytes lock) #""))
  (string-append (sha1 (open-input-bytes lock-bytes)) ":v1"))

(define (main)
  (define FLAKE (make-parameter #f))
  (define HOST (make-parameter #f))
  (define SYSTEM (make-parameter #f))
  (define OUT (make-parameter #f))

  (command-line
   #:program "nisp extract-packages"
   #:once-each
   [("--flake") f "flake root (default: git toplevel or cwd)"
    (FLAKE f)]
   [("--host") h "nixosConfiguration hostname (default: system hostname)"
    (HOST h)]
   [("--system") s "system architecture (default: x86_64-linux)"
    (SYSTEM s)]
   [("--out") o "output file (default: <flake-root>/.nisp-cache/packages.json)"
    (OUT o)]
   #:args () (void))

  (define flake-root
    (let* ([raw (or (FLAKE) (git-toplevel)
                    (path->string (current-directory)))]
           [trimmed (regexp-replace #rx"/$" raw "")])
      trimmed))

  (define host
    (or (HOST) (getenv "FIRN_HOST") (host-name)))

  (define system
    (or (SYSTEM) "x86_64-linux"))

  (define out-path
    (cond
      [(OUT) (OUT)]
      [else (path->string (build-path flake-root ".nisp-cache" "packages.json"))]))

  (make-directory* (or (path-only (string->path out-path)) (current-directory)))

  (printf "nisp extract-packages: extracting package names from ~a (host: ~a)...\n"
          flake-root host)

  (define expr
    (regexp-replaces NIX-EXPR
                     `((#rx"@FLAKE@"  ,flake-root)
                       (#rx"@HOST@"   ,host)
                       (#rx"@SYSTEM@" ,system))))

  (define nix (find-executable-path "nix"))
  (unless nix
    (eprintf "nisp extract-packages: `nix` not found in PATH.\n")
    (exit 2))

  (define stdout-bytes (open-output-bytes))
  (define stderr-str (open-output-string))
  (define ok?
    (parameterize ([current-output-port stdout-bytes]
                   [current-error-port stderr-str])
      (system* nix "eval" "--json" "--impure" "--expr" expr)))

  (unless ok?
    (eprintf "nisp extract-packages: nix eval failed.\n")
    (define err (get-output-string stderr-str))
    (when (non-empty-string? err) (eprintf "~a\n" err))
    (exit 1))

  (define raw-json (get-output-bytes stdout-bytes))
  (define result (read-json (open-input-bytes raw-json)))

  (define pkgs-list (hash-ref result 'pkgs '()))
  (define unstable-list (hash-ref result 'unstable '()))
  (define master-list (hash-ref result 'master '()))

  ;; Detect overlay packages: packages in pkgs but not in a vanilla nixpkgs
  ;; We approximate this by checking which host config overlays add.
  ;; For now, store an empty overlays list — users can populate it manually
  ;; or we can detect them in a future version.
  (define overlays '())

  (define output
    (hasheq 'key (cache-key flake-root)
            'sets (hasheq 'pkgs pkgs-list
                          'unstable unstable-list
                          'master master-list)
            'overlays overlays))

  (call-with-output-file out-path #:exists 'replace
    (λ (out) (write-json output out)))

  (printf "nisp extract-packages: cached ~a top-level + ~a unstable + ~a master package names → ~a\n"
          (length pkgs-list)
          (length unstable-list)
          (length master-list)
          out-path))
