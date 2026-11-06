# morphl-lsp

A language server for morphl, over stdio (LSP 3.17). It reports **diagnostics**: as a
document is opened, changed or saved, it is parsed and type-checked, and the checker's
errors are published against it. Hover, go-to-definition and completion are not there
yet — they need the checker to record what each name refers to and each expression's
type by position, which it does not do today.

## Building

```
zig build stage2 lsp        # zig-out/bin/mplc, then zig-out/bin/morphl-lsp
zig build test-lsp          # a recorded session, replies compared byte for byte
```

Linux only: each check runs the server's own binary again through `/proc/self/exe`.

## What it checks against

A document is checked as the file its URI names, with the editor's text in place of
what is on disk, so `$import`s resolve as `mplc`'s do — beside the file, then through
the search roots. The roots are the workspace's root folder and, in order, each entry of
`initializationOptions.roots`, a path relative to that folder or absolute:

```json
{ "roots": ["stage1"] }
```

With the morphl repository as the workspace, `std/…` imports resolve from the root;
`stage1` is needed only for a file that imports the compiler as `"compiler"`, as
`lsp/morphl_lsp.mpl` does.

An error raised in another file — an imported module, or a `$template`'s body checked
where it is used (SPEC §10.7) — is shown on the document's first line, naming where it is.
Only parse and inference run, not lowering, so the rare error only lowering reports is
not shown.

## Editors

**Neovim** (0.10+):

```lua
vim.filetype.add({ extension = { mpl = "morphl" } })
vim.api.nvim_create_autocmd("FileType", {
  pattern = "morphl",
  callback = function(ev)
    vim.lsp.start({
      name = "morphl-lsp",
      cmd = { "/path/to/morphl/zig-out/bin/morphl-lsp" },
      root_dir = vim.fs.root(ev.buf, { ".git" }),
      init_options = { roots = { "stage1" } },
    })
  end,
})
```

**Helix** (`languages.toml`):

```toml
[language-server.morphl-lsp]
command = "/path/to/morphl/zig-out/bin/morphl-lsp"
config = { roots = ["stage1"] }

[[language]]
name = "morphl"
scope = "source.morphl"
file-types = ["mpl"]
roots = [".git"]
language-servers = ["morphl-lsp"]
```

## How it works

The compiled runtime frees nothing a program does not `$free` (SPEC §7.6), and a check is
nearly all garbage, so a server that checked in its own process would grow with every
keystroke. So each check is a **process of its own**: the server writes the document to
a temporary file in `$XDG_RUNTIME_DIR` (or `/tmp`) and runs itself as
`morphl-lsp --check <buffer> <path> <out> [roots…]`, which checks the buffer as the
file `<path>` and writes every diagnostic to `<out>` as JSON (`std/json`). The process's
exit gives all of it back. The server itself keeps the documents' latest text.

The checker's columns are bytes; LSP's are UTF-16 code units, so the server converts each
against the document's text, and widens a diagnostic's start to the token there.
