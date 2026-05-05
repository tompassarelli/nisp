#lang nisp

;; Run: racket examples/hello.rkt
;; The output is the equivalent Nix program.

(raw-file
  (att
    (greeting (s "Hello, " name "!"))
    (numbers (lst 1 2 3 4 5))
    (meta (att
            (created-by "nisp")
            (version "0.1.0")))))
