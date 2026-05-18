# Editor setup

nisp ships an LSP server (`nisp-lsp`) that provides diagnostics,
hover, completion, code actions, and goto-definition. Point your
editor at it and you get the full validator feedback inline.

## Doom Emacs (lsp-mode)

```elisp
(after! lsp-mode
  (add-to-list 'lsp-language-id-configuration '(racket-mode . "nisp"))
  (lsp-register-client
   (make-lsp-client :new-connection (lsp-stdio-connection "nisp-lsp")
                    :major-modes '(racket-mode)
                    :server-id 'nisp-lsp)))
```

## Helix

In `languages.toml`:

```toml
[language-server.nisp]
command = "nisp-lsp"

[[language]]
name = "racket"
language-servers = ["nisp"]
```

## Neovim (lspconfig)

```lua
require'lspconfig.configs'.nisp = {
  default_config = {
    cmd = {'nisp-lsp'},
    filetypes = {'racket'},
    root_dir = require'lspconfig.util'.root_pattern('flake.rkt', 'flake.nix'),
  },
}
require'lspconfig'.nisp.setup{}
```

## VS Code

No dedicated extension yet. You can use a generic LSP client extension
(e.g. [vscode-languageclient](https://github.com/AuxoAI/vscode-languageclient))
pointed at `nisp-lsp` with `racket` as the language ID.
