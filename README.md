# nisp

**Statically-checked Lisp for Nix.** A Racket `#lang` that compiles to
Nix, paired with a checker that catches unknown option paths, type
mismatches, and enum violations at `file:line:col` — before
`nix-build` runs.

```
$ nisp validate
modules/printing/default.rkt:6:7: unknown option services.pipwire.alsa.enable
  did you mean: services.pipewire.alsa.enable?
hosts/laptop/configuration.rkt:11:47: type mismatch at boot.loader.systemd-boot.consoleMode:
  "atuo" not in enum {"0", "1", "2", "auto", "max", "keep"} — did you mean "auto"?
```

NixOS validates option paths and types too, but only during module
evaluation — by then the authoring context is gone and errors point at
the force site, not the mistake. Compiling from an eager language to a
lazy one buys you a walkable AST stage *before* emission. nisp
validates there, against the schema NixOS already publishes.

> **Is this *really* statically typed?** The type system being
> checked is NixOS's options schema, not one defined inside nisp — so
> strictly, gradually typed via external schema. Closer to TypeScript
> over JavaScript than to ML. Practically: errors before runtime, at
> the source line, with did-you-mean.

## A taste

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

Both `.rkt` and the emitted `.nix` are committed; the flake reads
ordinary Nix. You're not trapped — drop down to raw Nix anytime, or
stop using nisp by deleting the `.rkt` files.

## Install

Requires Racket 8.x. Nix is needed for `validate`'s submodule
expansion. Cargo is needed once to build `import`'s parser shim.

```bash
git clone https://github.com/tompassarelli/nisp
cd nisp
raco pkg install --link --auto
cd nix-parser && cargo build --release && cd ..
export PATH="$PWD/bin:$PATH"
```

## Usage

The toolchain is a single `nisp` binary plus a `nisp-lsp` server
(separate so editors can spawn it by name).

```bash
nisp extract-schema           # cache the options schema for your host
nisp validate                 # check every .rkt in the cwd's flake
nisp import some-config.nix   # convert existing Nix to nisp
```

Subcommands (`nisp <cmd> --help` for full options):

| command | what it does |
|---|---|
| `nisp validate` | walk `.rkt` sources, report unknown option paths + type mismatches with did-you-mean. `--auto-fix` rewrites unambiguous typos. |
| `nisp extract-schema` | dump an options tree (NixOS, home-manager, nix-darwin, anything `nixpkgs.lib.evalModules`-shaped) into `.nisp-cache/schema.json`. Re-run after `nix flake update`. |
| `nisp import [file]` | translate `.nix` → `.rkt`. Built on rnix-parser; 100% pass rate on all 2,332 nixpkgs/nixos modules; comments preserved. |
| `nisp schema <path>` | query the cached schema. `--children <prefix>` lists sub-options; `--search <query>` does fuzzy matching across all 16k+ paths. `--json` for machine-readable output. |
| `nisp rename <old> <new>` | rename an option path across every `.rkt` in the flake. Word-boundary matching; `--dry-run` previews. |
| `nisp edit <op> <file> ...` | programmatic, source-text-preserving edits: `set` / `unset` for `(set 'PATH val)` forms, `enable-add` / `enable-remove` for `(enable a b c)` lists. |
| `nisp-lsp` | LSP server (separate binary). Diagnostics, hover, completion, code actions, goto-definition. |

### Editor setup

```elisp
;; Doom Emacs (lsp-mode):
(after! lsp-mode
  (add-to-list 'lsp-language-id-configuration '(racket-mode . "nisp"))
  (lsp-register-client
   (make-lsp-client :new-connection (lsp-stdio-connection "nisp-lsp")
                    :major-modes '(racket-mode)
                    :server-id 'nisp-lsp)))
```

```toml
# Helix (languages.toml):
[language-server.nisp]
command = "nisp-lsp"

[[language]]
name = "racket"
language-servers = ["nisp"]
```

```lua
-- Neovim (lspconfig):
require'lspconfig.configs'.nisp = {
  default_config = {
    cmd = {'nisp-lsp'},
    filetypes = {'racket'},
    root_dir = require'lspconfig.util'.root_pattern('flake.rkt', 'flake.nix'),
  },
}
require'lspconfig'.nisp.setup{}
```

## Surface forms

Every Nix construct has a corresponding nisp form. Mappings are
mechanical:

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
| `(and a b)` / `(or a b)` / `(impl a b)` | `a && b` / `a \|\| b` / `a -> b` |
| `(== a b)` / `(!= a b)` / `(< a b)` etc. | comparison |
| `(+ a b)` / `(- a b)` / `(* a b)` / `(/ a b)` | arithmetic (variadic) |
| `(get base 'a.b.c)` | `base.a.b.c` |
| `(get-or base 'a.b.c default)` | `base.a.b.c or default` |
| `(has base 'a.b.c)` | `base ? a.b.c` |
| `(assert-do cond body)` | `assert cond; body` |
| `(spath "nixpkgs")` | `<nixpkgs>` |
| `(pipe-to x f)` / `(pipe-from f x)` | `x \|> f` / `f <\| x` (Nix 2.15+) |
| `(merge a b)` / `(concat-list a b)` / `(cat a b)` | `a // b` / `a ++ b` / `a + b` |

## Use as a library

The DSL exports its AST and emitter:

```racket
(require nisp)

(define expr
  (att
    (services.openssh.enable #t)
    (networking.firewall.allowedTCPPorts (lst 80 443))))

(displayln (emit expr 0))
```

`nisp/validate` exposes the building blocks behind `nisp validate` —
walk a parsed source, extract option-path references, infer value
shape, check against any schema you provide. Bring your own schema
source; nisp doesn't care whether it came from NixOS, home-manager,
or somewhere else.

## A NixOS framework on top

[firnos](https://github.com/tompassarelli/firnos) is a NixOS
configuration framework built on nisp — modules, bundles, host
configs, scaffolding, the `firn` CLI. If you want "Doom Emacs for
NixOS config", that's the one.

### Heads-up for downstream consumers (and AI agents)

A nisp-based repo typically commits **both** the `.rkt` and the
generated `.nix` next to each other. The flake reads the `.nix`, but
the `.nix` is a build artifact — regenerating from the `.rkt` will
overwrite direct `.nix` edits. **Always edit the `.rkt`.** Add a
`CLAUDE.md` / `AGENTS.md` to your config repo saying so explicitly,
since agents reaching in via absolute path from a different working
directory may not auto-load the file.

## Tests

```bash
raco test tests/
```

## Working on nisp itself

See [AGENTS.md](AGENTS.md) — repo layout, how to add a new DSL form /
subcommand / LSP capability, release process. Aimed at AI coding
agents but useful for any contributor.

## Status

`v0.12.0` — single-binary CLI (`nisp <subcommand>`) plus `nisp-lsp`.
Full Nix surface coverage. 77 tests. Output is byte-equivalent to
hand-written Nix on a real-world ~200-module config; `nisp import`
handles 100% of nixpkgs (2,332 modules) via rnix-parser. LSP provides
diagnostics, hover, completion, code actions, goto-definition. API
may shift before `v1.0` based on usage feedback.

## License

MIT
