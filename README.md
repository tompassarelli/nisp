# nisp

**An s-expression DSL that compiles to the Nix language.** A custom
Racket `#lang` for writing Nix code (NixOS modules, flakes, home-manager
config, derivations, anything) as Lisp, with full coverage of the Nix
expression grammar.

```racket
#lang nisp

(att
  (services.openssh.enable #t)
  (networking.firewall.allowedTCPPorts (lst 80 443))
  (users.users.tom (att (isNormalUser #t)
                        (shell pkgs.zsh)
                        (extraGroups (lst "wheel" "docker")))))
```

→

```nix
{
  services.openssh.enable = true;
  networking.firewall.allowedTCPPorts = [ 80 443 ];
  users.users.tom = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = [ "wheel" "docker" ];
  };
}
```

## Why

nisp gives you Nix's value model (lazy attrset/list/lambda) with Lisp's
authoring ergonomics and — crucially — an **eager AST stage** before
emission. Tools that walk a nisp program can do source-aware checks
that Nix can't: validate option paths against the NixOS schema,
type-check values, lint, refactor, generate documentation. All with
file:line:col precision pointing at your `.rkt` source, before any
`nix-build` runs.

`nisp` itself is just the language — small, dependency-free,
well-tested. The validator/CLI/framework that turn it into a NixOS
authoring tool live separately (see [Companion projects](#companion-projects)).

## Install

Requires Racket 8.x.

```bash
git clone https://github.com/tompassarelli/nisp
cd nisp
raco pkg install --link --auto
```

Verify:

```bash
echo '#lang nisp
(att (a 1) (b "hi") (c (lst 1 2 3)))' | racket -I racket/base -e '(read)'
```

## Quick reference

| nisp | nix |
|---|---|
| `(att (k v) ...)` | `{ k = v; ... }` |
| `(rec-att (k v) ...)` | `rec { k = v; ... }` |
| `(lst a b c)` | `[ a b c ]` |
| `(s "lit " expr)` | `"lit ${expr}"` |
| `(ms "line1" "line2")` | `''<NL>  line1<NL>  line2<NL>''` |
| `(p "./foo")` | `./foo` |
| `(let-in ([k v]...) body)` | `let k = v; ... in body` |
| `(with-do ns body)` | `with ns; body` |
| `(if-then c t e)` | `if c then t else e` |
| `(fn (a b) body)` | `a: b: body` |
| `(fn-set (a (b "default")) body)` | `{ a, b ? "default" }: body` |
| `(fn-set-rest (a b) body)` | `{ a, b, ... }: body` |
| `(fn-set@ self (a b) body)` | `{ a, b } @ self: body` |
| `(call f x y)` | `f x y` |
| `(inh a b)` / `(inh-from ns a b)` | `inherit a b;` / `inherit (ns) a b;` |
| `(not x)` / `(neg x)` | `!x` / `-x` |
| `(and a b c)` / `(or a b)` / `(impl a b)` | `a && b && c` / `a \|\| b` / `a -> b` |
| `(== a b)` / `(!= a b)` / `(< a b)` etc. | comparison |
| `(+ a b c)` / `(- a b)` / `(* a b)` / `(/ a b)` | arithmetic (variadic) |
| `(get base 'a.b.c)` | `base.a.b.c` |
| `(get-or base 'a.b.c default)` | `base.a.b.c or default` |
| `(has base 'a.b.c)` | `base ? a.b.c` |
| `(assert-do cond body)` | `assert cond; body` |
| `(spath "nixpkgs")` | `<nixpkgs>` |
| `(pipe-to x f)` / `(pipe-from f x)` | `x \|> f` / `f <\| x` (Nix 2.15+) |
| `(merge a b)` / `(concat-list a b)` / `(cat a b)` | `a // b` / `a ++ b` / `a + b` |

## Use as a library

`nisp` exports the AST nodes and emitter so other tools can produce or
consume nisp programs:

```racket
(require nisp)

(define expr
  (att
    (services.openssh.enable #t)
    (networking.firewall.allowedTCPPorts (lst 80 443))))

(displayln (emit expr 0))
;; →
;; {
;;   services.openssh.enable = true;
;;   networking.firewall.allowedTCPPorts = [ 80 443 ];
;; }
```

The full AST is exposed via `(struct-out ...)` for `nix-bool`,
`nix-int`, `nix-string`, `nix-attrs`, `nix-let`, `nix-lambda`,
`nix-binop`, `nix-unop`, `nix-select`, `nix-has-attr`, `nix-assert`, etc.

## Tests

```bash
raco test tests/
```

30 rackunit cases covering every AST node and surface form.

## Companion projects

- **[firnos](https://github.com/tompassarelli/firnos)** — a NixOS
  configuration framework built on nisp, with a schema-aware validator
  (`firn-validate`), CLI (`firn`), and module/bundle conventions. If
  you want "Doom Emacs for NixOS config", that's the one.

## Status

`v0.1.0` — Nix surface coverage is complete (every construct in
`src/libexpr/parser.y` has a nisp form). API may shift before `v1.0`
based on usage feedback. Tests pass, output is byte-equivalent to
hand-written Nix on a real-world ~200-module config.

## License

MIT
