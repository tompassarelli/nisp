# Agent context for nisp

Targeted at AI coding agents (Claude Code, Cursor, Codex, Aider, etc.)
working *on* the nisp project itself — not on configs that consume nisp.
For consumer-facing usage, see [README.md](README.md).

## What this repo is

A Racket `#lang` for writing Nix as s-expressions, plus the toolchain
that makes it useful: schema-driven validator, importer, LSP server,
programmatic editor.

## Repo layout

```
.
├── main.rkt              the DSL — AST nodes, surface forms, emitter
├── lang/reader.rkt       #lang-reader hook
├── info.rkt              Racket package metadata + version
├── validate.rkt          validation library (AST walk, infer, type-check)
├── validate-cache.rkt    schema loading + lazy submodule expansion
├── lsp.rkt               LSP server (consumes validate)
├── edit.rkt              programmatic source-edit library (set/unset)
├── cli/                  per-subcommand modules; each provides `main`
│   ├── validate.rkt          schema-driven .rkt validation
│   ├── extract-schema.rkt    dump options tree → JSON cache
│   ├── import.rkt            .nix → .rkt (calls Rust shim)
│   ├── schema.rkt            query schema (lookup/children/search)
│   ├── rename.rkt            rename option path across .rkt files
│   └── edit.rkt              programmatic set/unset/enable-add/remove
├── bin/
│   ├── nisp                  dispatcher: `nisp <subcommand> [args...]`
│   └── nisp-lsp              LSP launcher (separate so editors spawn by name)
├── nix-parser/           Rust crate wrapping rnix-parser
│   ├── src/main.rs           parses Nix, emits JSON AST + comments
│   └── Cargo.toml            cargo build --release before `nisp import` works
├── tests/                rackunit suite
│   ├── emit-test.rkt         covers every AST node + surface form
│   ├── validate-test.rkt     covers validation library
│   ├── edit-test.rkt         covers edit primitives
│   ├── cli-test.rkt          dispatcher + subcommand smoke tests
│   └── lsp-test.rkt          subprocess JSON-RPC tests for nisp-lsp
└── examples/             runnable .rkt examples
```

## Running tests

```bash
raco pkg install --link --auto    # one-time; links this dir as the nisp pkg
raco setup nisp                   # rebuild after edits
raco test tests/                  # run the suite (77 tests)

cd nix-parser && cargo build --release   # required for `nisp import`
```

## Adding a new surface form to the DSL

Pattern (worked example: adding `pipe-to` for Nix's `|>` operator):

1. **AST**: in `main.rkt`, the form usually maps to an existing node
   (`nix-binop`, `nix-unop`, `nix-app`, etc.). Add a new struct only if
   the syntactic shape isn't expressible with what's there.
2. **Surface form**: define a function (preferred) or macro that takes
   user args and returns AST. Keep names short, idiomatic Lisp.
3. **Provide it**: add to the `provide` list at the top of `main.rkt`.
   Use `rename-out` if the user-facing name conflicts with Racket builtins.
4. **Emitter**: usually no change needed if you reused an existing AST
   node. If you added a new node, add a case to `emit` and an
   `emit-NODENAME` function.
5. **`parens-if-needed`**: if the new node should be parenthesized when
   it appears as an operand of higher-precedence operators, add it to
   the list.
6. **Test**: add cases to `tests/emit-test.rkt`. One per new function/macro.
7. **Docs**: add a row to the README's quick-reference table.

Gotchas:
- Some Lisp identifiers can't be written literally because of the
  bar-quote convention: `||` reads as the empty symbol, `|>` is a parse
  error. Use `(string->symbol "||")` to construct them. See `OR-SYM`
  and `PIPE-TO-SYM` in main.rkt.
- Racket's `and`, `or`, `not` are shadowed by nisp's `and`, `or`, `not`
  inside `#lang nisp` files. That's intentional — those forms emit Nix
  ops. If you need Racket's behavior inside main.rkt itself, use
  `racket/base`'s versions.

## Adding a new subcommand

The user-facing CLI is a single `nisp` dispatcher (`bin/nisp`) plus a
separate `nisp-lsp` (kept separate so editors can spawn it by exact
executable name). Each subcommand is a `cli/<name>.rkt` library that
provides `main`. The dispatcher slices off the subcommand argument
and `parameterize`s `current-command-line-arguments`, then
`dynamic-require`s the module's `main`.

To add a subcommand:

1. **New module**: `cli/<name>.rkt`. Use `#lang racket/base` (no
   shebang — it's a library). Wrap the body in `(define (main) ...)`
   and `(provide main)`. Keep arg-parsing inside `main` so
   `command-line` reads from the dispatcher's parameterized
   `current-command-line-arguments`. Use `#:program "nisp <name>"` so
   usage strings match the user-facing form.
2. **Register**: add a case to `dispatch` in `bin/nisp`, including a
   one-line entry in `HELP`.
3. **Document**: add a row to README's subcommand table.
4. **Test**: add a smoke case to `tests/cli-test.rkt`. Invoke through
   `run-nisp` (which calls `bin/nisp <subcommand>`), not the module
   directly — the test should exercise the dispatcher path.

Don't reach for new top-level binaries unless there's a real reason
(`nisp-lsp` qualifies — editors spawn LSPs by exact name).

## Adding LSP capability

`lsp.rkt` is hand-rolled JSON-RPC over stdio. Pattern for a new method:

1. Add the capability to the `initialize` response's `capabilities` hash
2. Add a `[(equal? method "textDocument/X") ...]` clause in `handle-message`
3. Implement `handle-X` returning the response shape per LSP spec

Test by feeding the server LSP messages over stdio (see
`tests/lsp-*.py` if added; otherwise use the python test pattern from
the v0.6.0/v0.7.0 commit messages).

## How releases work

```bash
# 1. bump version
sed -i 's/version "0.X.Y"/version "0.X+1.Y"/' info.rkt

# 2. README "Status" line — update version + summary

# 3. commit + tag + push + release notes
git add -A
git commit -m "0.X+1.Y — short description"
git push
git tag -a v0.X+1.Y -m "v0.X+1.Y — short description"
git push origin v0.X+1.Y
gh release create v0.X+1.Y --title "v0.X+1.Y" --notes "..."
```

Use lightweight tags (`git tag NAME COMMIT`, no `-a`) only if you need
to fix release ordering — see firnos's commit history for the rationale.

## Don't-do list

- **Don't break AST node names or fields.** firnos's validator and
  consumers depend on the struct shapes. Renaming `nix-attrs` →
  `nix-attrset` is a breaking change. If you must, coordinate with
  firnos in the same release.
- **Don't add required fields to AST structs without good reason.** The
  parser, importer, and validator all construct these. Optional fields
  via `make-X` helpers are safer.
- **Don't introduce hidden global state in lsp.rkt.** Tests subprocess
  the server and rely on isolation per spawn. Module-level mutables are
  OK (documents, schema-table) because each subprocess has its own
  instance.
- **Don't bypass `nisp/validate` primitives in lsp.rkt or new
  subcommands.** That module is the canonical source for
  path-walking, type-checking, did-you-mean. Reusing it keeps
  behavior consistent across the toolchain.
- **Don't reintroduce per-tool binaries.** The toolchain is
  intentionally a single `nisp` dispatcher (plus `nisp-lsp` for
  editor spawn-by-name). New tools become `cli/<name>.rkt`
  subcommands.

## Where things connect

- `validate.rkt` is the kernel. `cli/validate.rkt`, `lsp.rkt`, and
  any future tooling that checks `.rkt` files should
  `(require nisp/validate)` rather than reimplementing.
- `main.rkt` defines the AST. Anyone constructing nisp from outside
  (importer, LSP code-actions emitting source, future code-generators)
  should produce values via the surface forms, not raw struct
  construction.
- The Rust shim is the only foreign-language component. Its JSON output
  format is the wire protocol — adding fields is non-breaking, removing
  or renaming is breaking. Update `cli/import.rkt` in lockstep.

## Useful one-liners

```bash
# Round-trip test: import every .nix in a target repo, re-emit, diff
for f in $(find /target -name "*.nix"); do
  bin/nisp import "$f" 2>/dev/null | racket -I racket/base /dev/stdin > /tmp/out 2>/dev/null
  diff -q "$f" /tmp/out
done

# Time the schema extractor (should be ~3s for whiterabbit's tree)
time bin/nisp extract-schema --target nixosConfigurations.whiterabbit.options --flake /home/tom/code/nixos-config

# Smoke-test the LSP via stdio (see commit history for the python harness)
```
