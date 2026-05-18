# Language reference

Every Nix construct has a corresponding nisp form. Mappings are
mechanical — if you know the Nix, you know the nisp.

## Surface forms

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

## Module-shape forms

The forms above cover raw Nix. NixOS modules also have a standard
shape (`{ config, lib, pkgs, ... }: let cfg = ...; in { options...;
config = mkIf cfg.enable {...}; }`), and writing that by hand for
every module is repetitive. nisp ships file-level wrappers that emit
that shape from a short declaration:

```racket
#lang nisp

(module-file modules ripgrep
  (desc "ripgrep — fast recursive grep")
  (tags cli)
  (config-body
    (set environment.systemPackages (with-pkgs ripgrep))))
```

This emits the full `{ config, lib, pkgs, ... }: let cfg =
config.myConfig.modules.ripgrep; in { options.myConfig.modules.ripgrep.enable
= lib.mkEnableOption "ripgrep — fast recursive grep"; config =
lib.mkIf cfg.enable { … }; }` wrapper.

### File-level forms

Each writes a complete `.nix`:

| form | what it wraps |
|---|---|
| `(module-file <ns> <name> clause...)` | NixOS module with auto `enable` option + `mkIf` config block |
| `(bundle-file <name> clause...)` | a "bundle" — enables a list of modules via `mkDefault` |
| `(host-file form...)` | top-level host config; forms become entries in the resulting attrset |
| `(hm-module <name> <desc> body...)` | home-manager-only module (option lives under `myConfig.home.<name>`) |
| `(hm-file form...)` | top-level home-manager config |
| `(flake-file form...)` | top-level `flake.nix` shape (inputs / outputs) |
| `(raw-file expr)` | escape hatch — emit one arbitrary expression, no wrapping |

### Clauses inside `(module-file …)`

Every clause is optional:

| clause | what it does |
|---|---|
| `(desc "...")` | description string passed to `mkEnableOption` |
| `(tags a b c)` | orthogonal facets for discovery — recorded in source, never emitted to `.nix` |
| `(option-attrs (k1 mkopt-call) (k2 …) …)` | declare extra options beyond `enable` |
| `(config-body form...)` | body of the `config = mkIf cfg.enable { … }` block |
| `(raw-body form...)` | bypass the `mkIf` wrapper — emit forms at the top level of `config` |
| `(sub-modules a b c)` | (for `bundle-file`) shorthand for `(set myConfig.modules.<a>.enable (mkDefault #t)) …` |
| `(sub-modules* (a "rename-to") b)` | sub-modules with optional renames |
| `(extra-args sym …)` | additional names to destructure from the module argument |
| `(lets ([k v] …))` | extra `let` bindings inside the wrapper |
| `(no-enable)` | suppress the auto `enable` option (use when the module shouldn't be toggleable) |

### Module-body convenience forms

| form | what it does |
|---|---|
| `(set 'path value)` / `(set path value)` | `path = value;` — option assignment. The bare-id form (no quote) is preferred when the path is a literal identifier. |
| `(enable a b c …)` | `a.enable = true; b.enable = true; …` — concise multi-toggle |
| `(pkg <name> "desc")` | shorthand for a `(module-file …)` that installs `pkgs.<name>` and nothing else |
| `(svc <name> "desc")` | symmetric `(pkg …)` for systemd services — turns into `(set services.<name>.enable #t)` plus an enable option |
| `(with-pkgs a b c)` | `with pkgs; [ a b c ]` |
| `(home-of <user> body...)` | wrap forms under `home-manager.users.<user>` |
| `(sops-secret 'name)` / `(sops-template 'name)` | references to sops-managed secrets |

### `mk*` helpers

Mirror NixOS lib:

| form | nix |
|---|---|
| `(mkif c x)` | `lib.mkIf c x` |
| `(mkdefault x)` | `lib.mkDefault x` |
| `(mkforce x)` | `lib.mkForce x` |
| `(mkmerge xs)` | `lib.mkMerge xs` |
| `(mkenable "desc")` | `lib.mkEnableOption "desc"` |
| `(mkopt #:type T #:default D #:desc S)` | `lib.mkOption { type = T; default = D; description = S; }` |

### Type helpers

For `mkopt`'s `#:type`: `t-bool`, `t-str`, `t-int`, `t-path`,
`t-port`, `(t-listof T)`, `(t-attrsof T)`, `(t-nullor T)`,
`(t-enum "a" "b" …)`, `(t-submodule shape)`.
