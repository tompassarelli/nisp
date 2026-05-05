# nisp

**Statically-checked Lisp for Nix.** A small Racket `#lang` that
compiles to the Nix language, paired with a checker that catches
unknown option paths, type mismatches, and enum violations at
`file:line:col` precision — before `nix-build` runs.

```
$ nisp-validate
modules/printing/default.rkt:6:7: unknown option services.pipwire.alsa.enable
  did you mean: services.pipewire.alsa.enable or services.pipewire.pulse.enable?
modules/foo/default.rkt:9:34: type mismatch at services.openssh.enable:
  expected bool, got string
hosts/laptop/configuration.rkt:11:47: type mismatch at boot.loader.systemd-boot.consoleMode:
  "atuo" not in enum {"0", "1", "2", "5", "auto", "max", "keep"} — did you mean "auto"?
```

The reason this works isn't the parens — it's that compiling from an
eager language to a lazy one buys you something Nix itself can't
easily do: a walkable AST stage *before* emission. NixOS validates
option paths and types too, but only during module evaluation, by
which point the original authoring context has been discarded and
errors point at the force site instead of the mistake. nisp validates
earlier, against the concrete source AST, with the option schema NixOS
already publishes.

> **Is this *really* statically typed?** The type system being checked
> is NixOS's options schema, not a type system defined inside nisp —
> so strictly, nisp is gradually typed via external schema. Closer in
> spirit to TypeScript over JavaScript or `ajv` over JSON than to ML.
> Practically: errors before runtime, at the source line, with
> did-you-mean. That's the bar most people mean.

The DSL itself is small and predictable — every Nix construct has a
form, mappings are mechanical:

```racket
#lang nisp

(raw-file
  (att
    (services.openssh.enable #t)
    (networking.firewall.allowedTCPPorts (lst 80 443))
    (users.users.tom (att (isNormalUser #t)
                          (shell pkgs.zsh)
                          (extraGroups (lst "wheel" "docker"))))))
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

Both `.rkt` source and emitted `.nix` are committed; the flake reads
ordinary Nix. You're not trapped — drop down to raw Nix anytime, or
stop using nisp by deleting the `.rkt` files.

## What ships

- **The DSL** (`#lang nisp`) — every construct in Nix's expression grammar has a corresponding nisp form.
- **`nisp/validate`** (library) — AST walker, value-type inference, schema-driven type checker, Levenshtein did-you-mean. Pure functions over a parsed nisp source and a schema-table.
- **`bin/nisp-extract-schema`** — dumps an options tree (NixOS, home-manager, nix-darwin, any Nix-options-system tree) into a JSON schema cache.
- **`bin/nisp-validate`** — discovers option-path references in your `.rkt` sources, lazy-expands submodules on demand, type-checks values, reports errors with `file:line:col` precision.

The CLIs are configurable via `--target`, `--cache-dir`, `--flake`,
`--hm-roots`. `nixosConfigurations.<host>.options` is the default
target — override for home-manager-only, nix-darwin, or anything else.

A NixOS configuration framework built on top of all this lives separately at [firnos](https://github.com/tompassarelli/firnos) — modules, bundles, host configs, scaffolding, the `firn` CLI for daily workflow.

## Install

Requires Racket 8.x and (for the validator's submodule expansion) Nix.

```bash
git clone https://github.com/tompassarelli/nisp
cd nisp
raco pkg install --link --auto
```

Add `nisp/bin` to your `PATH` (or invoke the scripts by absolute path):

```bash
export PATH="$HOME/code/nisp/bin:$PATH"
nisp-extract-schema   # cache a schema for your current host
nisp-validate         # validate every .rkt in the cwd's flake
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

### Validation primitives

`nisp/validate` provides the building blocks for source-aware
validation: walk a parsed source, extract every option-path reference,
infer each value's static shape, and check it against your schema:

```racket
(require nisp/validate)

;; You provide schema-table: hash from path → entry hash with 't, 'inner, 'enum.
(define schema-table
  (hash "services.openssh.enable" (hasheq 't "bool")
        "networking.firewall.allowedTCPPorts"
        (hasheq 't "listOf" 'inner (hasheq 't "unsignedInt16"))))

;; Walk syntax, validate every set/enable.
(walk-syntax (read-syntax 'src port)
  (λ (stx in-hm?)
    (for ([pr (in-list (extract-from-form stx))])
      (define p (path-ref-path pr))
      (cond
        [(hash-has-key? schema-table p)
         (when (path-ref-val-stx pr)
           (define vt (infer-value-type (path-ref-val-stx pr)))
           (define result (check-type (hash-ref schema-table p) vt))
           (when (and (pair? result) (eq? (car result) 'mismatch))
             (eprintf "type mismatch at ~a: ~a\n" p (cadr result))))]
        [else
         (eprintf "unknown option ~a (did you mean: ~a?)\n"
                  p (find-similar-strs p (hash-keys schema-table)))]))))
```

Bring your own schema source — the NixOS options tree, a home-manager
options dump, your own custom config schema. nisp doesn't care.

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

`v0.3.0` — Language + validation library + CLI tools (`nisp-validate`,
`nisp-extract-schema`). Full Nix surface coverage. 47 tests. Output is
byte-equivalent to hand-written Nix on a real-world ~200-module config.
API may shift before `v1.0` based on usage feedback.

## License

MIT
