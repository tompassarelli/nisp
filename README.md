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

NixOS already validates option paths and types, but only at module
evaluation time — errors point at the force site, not the typo. nisp
compiles from an eager language to a lazy one, which means there's a
walkable AST *before* anything gets emitted. The validator runs there,
checking against the options schema NixOS publishes and a cached index
of 25K+ nixpkgs attribute names.

> **Is this really statically typed?** It checks NixOS's options
> schema, not a type system defined inside the language — closer to
> TypeScript over JavaScript than to ML. The practical result: errors
> before runtime, at the source line, with did-you-mean suggestions.

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
stop using nisp entirely by deleting the `.rkt` files.

## Install

Requires Racket 8.x, Nix (for schema extraction), and Cargo (one-time
build of the `import` parser shim).

```bash
git clone https://github.com/tompassarelli/nisp
cd nisp
raco pkg install --link --auto
cd nix-parser && cargo build --release && cd ..
export PATH="$PWD/bin:$PATH"
```

## Usage

```bash
nisp extract-schema           # cache the options schema for your host
nisp validate                 # check every .rkt in the cwd's flake
nisp import some-config.nix   # convert existing Nix to nisp
```

The toolchain is a single `nisp` dispatcher. Run `nisp <cmd> --help`
for full options on any subcommand.

| command | what it does |
|---|---|
| `validate` | check `.rkt` sources for unknown option paths, type mismatches, invalid package names, and duplicate assignments. `--auto-fix` rewrites unambiguous typos. |
| `extract-schema` | dump an options tree into `.nisp-cache/schema.json`. Works with NixOS, home-manager, nix-darwin — anything `evalModules`-shaped. Re-run after `nix flake update`. |
| `extract-packages` | dump nixpkgs attribute names into `.nisp-cache/packages.json` for package-name validation. |
| `import [file]` | translate `.nix` → `.rkt`. Comments preserved. 100% pass rate on all 2,332 nixpkgs/nixos modules. |
| `schema <path>` | query the cached schema: `--children`, `--search` (fuzzy), `--json`. |
| `rename <old> <new>` | rename an option path across every `.rkt` in the flake. `--dry-run` to preview. |
| `edit <op> <file>` | source-preserving edits: `set`/`unset`, `enable-add`/`enable-remove`. |

`nisp-lsp` is a separate binary (so editors can spawn it by name)
providing diagnostics, hover, completion, code actions, and
goto-definition. See [editor setup](docs/editor-setup.md) for
configuration.

## Further reading

- [Language reference](docs/language-reference.md) — surface forms, module-shape wrappers, `mk*` helpers, type helpers
- [Editor setup](docs/editor-setup.md) — LSP configuration for Doom Emacs, Helix, Neovim
- [API](docs/api.md) — using nisp as a Racket library
- [AGENTS.md](AGENTS.md) — repo internals, contributor guide, release process

## Ecosystem

[firnos](https://github.com/tompassarelli/firnos) is a NixOS
configuration framework built on nisp — modules, bundles, host
configs, scaffolding, the `firn` CLI. If you want "Doom Emacs for
NixOS config", that's the one.

A nisp-based repo typically commits **both** the `.rkt` and the
generated `.nix` side by side. The flake reads the `.nix`, but it's a
build artifact — **always edit the `.rkt`**. If you're an AI agent
reaching in from another working directory, note that you won't
auto-load this repo's instructions; add a `CLAUDE.md` / `AGENTS.md`
to your config repo to make the convention explicit.

## Status

v0.13.0. Full Nix surface coverage, 77 tests.

Validates a real-world 211-file config in ~5 seconds. `nisp import`
handles 100% of nixpkgs (2,332 modules). The LSP covers diagnostics,
hover, completion, code actions, and goto-definition.

API may shift before v1.0 based on usage feedback.

## Tests

```bash
raco test tests/
```

## License

MIT
