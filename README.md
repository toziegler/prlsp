# PRLSP

`prlsp` is an LSP server for surfacing GitHub PR review comments in-editor (as diagnostics), with commands/code-actions to create replies and new comments.

This repository also ships an Emacs package at `emacs/prlsp.el` and Neovim plugin at root directory.

## Emacs package (`emacs/prlsp.el`)

The package provides Emacs-side UX helpers (without changing the LSP protocol):

- `prlsp-comment-on-line`: open a markdown popup and submit a **new** review comment
- `prlsp-reply-on-line`: open a markdown popup and submit a **reply** to an existing thread
- `prlsp-show-thread`: show full thread content in a markdown side buffer
- `prlsp-mode`: minor mode auto-enabled only when the active server is `prlsp`

> No keybindings are installed by default. Bind commands in your config.

## straight.el setup

```emacs-lisp
(use-package prlsp
  :straight (:host github :repo "toziegler/prlsp" :files ("emacs/*.el"))
  :init
  ;; Optional customization before setup:
  ;; (setq prlsp-command '("prlsp_go"))
  ;; (setq prlsp-preferred-backend 'lsp) ; or 'eglot
  ;; (setq prlsp-auto-start t)
  :config
  (prlsp-setup))
```

### Example bindings (vanilla Emacs)

```emacs-lisp
(global-set-key (kbd "C-c p c") #'prlsp-comment-on-line)
(global-set-key (kbd "C-c p r") #'prlsp-reply-on-line)
(global-set-key (kbd "C-c p s") #'prlsp-show-thread)
```

## Doom Emacs setup

### `packages.el`

```emacs-lisp
(package! prlsp
  :recipe (:host github :repo "toziegler/prlsp" :files ("emacs/*.el")))
```

### `config.el`

```emacs-lisp
(use-package! prlsp
  :init
  ;; Optional:
  ;; (setq prlsp-preferred-backend 'lsp)
  ;; (setq prlsp-command '("prlsp_go"))
  :config
  (prlsp-setup)
  (map! 
        :localleader
        (:prefix ("p" . "prlsp")
         :desc "New PR comment" "c" #'prlsp-comment-on-line
         :desc "Reply to thread" "r" #'prlsp-reply-on-line
         :desc "Show thread" "s" #'prlsp-show-thread))
         )
```

## Notes

- `prlsp-setup` registers both `lsp-mode` and `eglot` integrations.
- `prlsp-preferred-backend` only controls which auto-start hooks are added.
- If you prefer manual startup, set `(setq prlsp-auto-start nil)` and start your backend yourself.

## Neovim plugin

The plugin provides Lua API:

- `require("prlsp").comment({ start_line, end_line })`  
  Open a markdown buffer to write a new PR comment on the given line range.  
  If no range is provided, the current line or visual selection is used.

- `require("prlsp").reply_on_line()`  
  Open a markdown buffer to reply to a PR review thread on the current line.

- `require("prlsp").show_thread()`  
  Show the full PR review thread for the current line in a markdown side buffer.

- `require("prlsp").refresh()`  
  Refresh PR review threads.

And the equivalent Ex-commands:

- `:PRLSPComment`
- `:PRLSPReplyOnLine`
- `:PRLSPShowThread`
- `:PRLSPRefresh`

### Plugin installation

```lua
-- Neovim 0.12+ required
vim.pack.add({ "https://github.com/toziegler/prlsp" })
```

### LSP setup

```lua
-- Note: plugin hardcodes prlsp LSP name
vim.lsp.config('prlsp', {
  cmd = { 'prlsp' }, -- Name of LSP executable or path
  root_markers = { '.git' },
})

vim.lsp.enable({'prlsp'})
```

### Keymap binding example

```lua
vim.keymap.set('', '<Leader>r', function()
  require('prlsp').reply_on_line()
end)
```
