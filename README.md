# nisp

**Statically-checked Lisp for Nix.** A Racket `#lang` that compiles to
Nix, paired with a checker that catches unknown option paths, type
mismatches, and enum violations at `file:line:col` — before
`nix-build` runs.

```
$ nisp validate
modules/printing/default.rkt:6:7: unknown option services.pipwire.alsa.enable
  did you mean: services.pipewire.alsa.enable?
modules/net/default.rkt:10:47: unknown package networkmanagers in pkgs set
  did you mean: networkmanager, networkmanager-ssh or networkmanager-sstp?
hosts/laptop/configuration.rkt:11:47: type mismatch at boot.loader.systemd-boot.consoleMode:
  "atuo" not in enum {"0", "1", "2", "auto", "max", "keep"} — did you mean "auto"?
modules/foo/default.rkt:8:9: duplicate assignment to networking.hostName (first set at line 5)
```

NixOS validates option paths and types too, but only during module
evaluation — by then the authoring context is gone and errors point at
the force site, not the mistake. Compiling from an eager language to a
lazy one buys you a walkable AST stage *before* emission. nisp
validates there, against the schema NixOS already publishes — plus a
cached index of 25K+ nixpkgs attribute names for package-level
checking.

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

| command | what it does |
|---|---|
| `nisp validate` | walk `.rkt` sources, report unknown option paths + type mismatches + invalid package names + duplicate assignments, all with did-you-mean. `--auto-fix` rewrites unambiguous typos. `--no-packages` skips package checks. |
| `nisp extract-schema` | dump an options tree (NixOS, home-manager, nix-darwin, anything `nixpkgs.lib.evalModules`-shaped) into `.nisp-cache/schema.json`. Re-run after `nix flake update`. |
| `nisp extract-packages` | dump top-level package attr names (pkgs + unstable + master, with overlays) into `.nisp-cache/packages.json`. Enables package-name validation. |
| `nisp import [file]` | translate `.nix` → `.rkt`. Built on rnix-parser; 100% pass rate on all 2,332 nixpkgs/nixos modules; comments preserved. |
| `nisp schema <path>` | query the cached schema. `--children <prefix>` lists sub-options; `--search <query>` does fuzzy matching across all 16k+ paths. `--json` for machine-readable output. |
| `nisp rename <old> <new>` | rename an option path across every `.rkt` in the flake. Word-boundary matching; `--dry-run` previews. |
| `nisp edit <op> <file> ...` | programmatic, source-text-preserving edits: `set` / `unset` for `(set 'PATH val)` forms, `enable-add` / `enable-remove` for `(enable a b c)` lists. |
| `nisp-lsp` | LSP server (separate binary). Diagnostics, hover, completion, code actions, goto-definition. |

See `nisp <cmd> --help` for full options.

## Documentation

| doc | covers |
|---|---|
| [Language reference](docs/language-reference.md) | surface forms, module-shape wrappers, clauses, convenience forms, `mk*` helpers, type helpers |
| [Editor setup](docs/editor-setup.md) | Doom Emacs, Helix, Neovim (LSP configuration) |
| [API](docs/api.md) | using nisp as a Racket library |
| [AGENTS.md](AGENTS.md) | repo layout, how to add forms / subcommands / LSP capabilities, release process (aimed at AI coding agents but useful for any contributor) |

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

## Status

`v0.13.0` — single-binary CLI (`nisp <subcommand>`) plus `nisp-lsp`.
Full Nix surface coverage. 77 tests. Validates option paths, value
types, enum values, package names (25K+ attrs cached per package set),
and duplicate assignments across a real-world 211-file config in ~5
seconds. `nisp import` handles 100% of nixpkgs (2,332 modules) via
rnix-parser. LSP provides diagnostics, hover, completion, code
actions, goto-definition. API may shift before `v1.0` based on usage
feedback.

## License

MIT
