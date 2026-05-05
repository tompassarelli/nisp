#lang nisp

;; A minimal Nix derivation: stdenv.mkDerivation { ... }
(raw-file
  (call stdenv.mkDerivation
    (att
      (pname "hello-nisp")
    (version "0.1.0")
    (src (call fetchFromGitHub
                 (att (owner "tompassarelli")
                      (repo "nisp")
                      (rev "v0.1.0")
                      (sha256 ""))))
    (buildInputs (with-pkgs racket-minimal))
      (installPhase (ms "mkdir -p $out/bin"
                        "cp $src/main.rkt $out/bin/")))))
