# kotlin-lite.nvim

Grep-based Kotlin navigation for Neovim — **no LSP required**. It uses `ripgrep`
plus Kotlin-aware regex heuristics to give you IntelliJ-style motions for `.kt` /
`.kts` files. Great for large Kotlin/Android codebases where a full LSP is slow
or unavailable, and for reading library sources extracted from `*-sources.jar`.

## Features

| Default keymap        | Action                                                                 |
| --------------------- | ---------------------------------------------------------------------- |
| `gd`                  | Go to definition — current buffer first (locals, params, lambda params, for-vars, properties, funs, classes), then project-wide + extracted jar sources |
| `K`                   | Hover: declaration + KDoc in a floating window                         |
| `gK`                  | Signature of the function whose call the cursor is inside              |
| `gr` / `<leader>fu`   | Find usages → quickfix panel at the bottom                             |
| `<leader>cr`          | Rename: project-wide word search & replace with confirmation           |
| `<leader>cs`          | File structure popup (IntelliJ `Ctrl+F12`)                             |
| `<leader>cS`          | Go to symbol in project (IntelliJ `Ctrl+N`)                            |
| `<leader>fe`          | Reveal current file in the [snacks.nvim] explorer (IntelliJ `Alt+F1`)  |
| `<leader>ka`          | Alternate file: `src/main/kotlin/X.kt` ⇄ `src/test/kotlin/XTest.kt` (created if missing) |
| `<leader>kc`          | Copy the file's fully-qualified name (`package.ClassName`) to the `+` register |
| `<leader>ki`          | Auto-import the symbol under the cursor (rg for the definition, picker if ambiguous) |
| `=` (operator)        | Format via `equalprg` — `==`, `=` + motion, or visual `=` (ktlint by default) |

Commands:

- `:KotlinSources` — find a `*-sources.jar` under `~/.gradle` / `~/.m2` and
  extract it so navigation can reach into library sources.
- `:KotlinSourcesClear` — clear the extracted jar cache.

## Requirements

- Neovim ≥ 0.10
- [`ripgrep`](https://github.com/BurntSushi/ripgrep) (`rg`), `unzip`, `find` on `PATH`
- (optional) [snacks.nvim] for `<leader>fe`

Project root is the directory Neovim was opened in (`getcwd()`).

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "olekdia/kotlin-lite.nvim", -- or a local `dir = "..."`
    ft = { "kotlin" },
    opts = {}, -- calls require("kotlin-lite").setup(opts)
}
```

The plugin works with zero configuration. `setup()` is only needed to override
defaults.

## Configuration

```lua
require("kotlin-lite").setup({
    filetypes = { "kotlin" },
    cache_dir = vim.fn.stdpath("cache") .. "/kotlin-lite-jars",
    jar_search_roots = {
        "~/.gradle/caches/modules-2/files-2.1",
        "~/.m2/repository",
    },
    formatprg = "ktlint --format --stdin", -- buffer-local 'equalprg' for the `=` operator
    intellij_keymaps = false,               -- register IntelliJ maps in addition to the vim ones
    keymaps = {
        goto_definition    = "gd",
        hover              = "K",
        signature_help     = "gK",
        find_usages        = { "gr", "<leader>fu" },
        rename             = "<leader>cr",
        file_structure     = "<leader>cs",
        project_symbols    = "<leader>cS",
        reveal_in_explorer = "<leader>fe",
        alternate_file     = "<leader>ka",
        copy_fqname        = "<leader>kc",
        auto_import        = "<leader>ki",
    },
})
```

Set any keymap to `false` to disable it. Each value may be a single lhs or a
list of them. Set `formatprg = ""` to leave `equalprg` untouched.

### IntelliJ keymaps

With `intellij_keymaps = true` these are added on kotlin buffers (on top of the
vim maps above):

| Key            | Action                                        |
| -------------- | --------------------------------------------- |
| `<C-n>`        | Find files (Telescope / snacks, best-effort)  |
| `<S-F6>`       | Rename symbol                                  |
| `<C-A-l>`      | Format buffer                                  |
| `<C-S-t>`      | Alternate file (go to test)                    |
| `<M-CR>`       | Auto-import under cursor (Alt+Enter)           |

## Layout

```
lua/kotlin-lite/
├── init.lua      -- setup()/init(), autocmds, user commands
├── config.lua    -- defaults + option merging
├── jars.lua      -- *-sources.jar discovery, extraction, read-only cache
├── search.lua    -- ripgrep + Kotlin decl patterns + in-buffer search
├── actions.lua   -- gd / K / gK / gr / rename / structure / symbols / alternate / fqname / auto-import / format
└── keymaps.lua   -- buffer-local keymap attachment
plugin/kotlin-lite.lua  -- startup bootstrap
tests/                  -- fixtures + interactive harness + headless checks
```

See [`tests/README.md`](tests/README.md) to try it live or run the checks.

[snacks.nvim]: https://github.com/folke/snacks.nvim
