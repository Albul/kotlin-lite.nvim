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
| `gu` / `grr`          | Find usages → quickfix panel at the bottom                             |
| `<leader>cr`          | Rename symbol: project-wide word search & replace with confirmation    |
| `<leader>cR`          | Rename file; for a same-named top-level `class`/`interface`/`object`/`fun` it offers a module-scoped symbol rename |
| `<leader>cs`          | File structure outline — top-level decls, class members & public fields, with kind icons (IntelliJ `Ctrl+F12`) |
| `<leader>cS`          | Go to symbol in project (IntelliJ `Ctrl+N`)                            |
| `<leader><leader>`    | Go to file (Telescope / snacks, best-effort)                           |
| `<leader>ke`          | Reveal current file in the [snacks.nvim] explorer (IntelliJ `Alt+F1`)  |
| `<leader>ka`          | Alternate file: `X.kt` ⇄ `XTest.kt` — searches the module for the `Test`-suffixed counterpart wherever it lives, and offers to scaffold it if absent |
| `<leader>cf`          | Format the whole buffer via `formatprg` (ktlint by default)            |
| `<leader>kc`          | Copy the file's fully-qualified name (`package.ClassName`) to the `+` register |
| `<leader>ki`          | Auto-import the symbol under the cursor (rg for the definition, picker if ambiguous) |
| `<leader>kr`          | Run the current file (needs a top-level `main()`) in a bottom terminal split |
| `<leader>kR`          | Run the project in a bottom terminal split                             |

Commands:

- `:KotlinSources` — find a `*-sources.jar` under `~/.gradle` / `~/.m2` and
  extract it so navigation can reach into library sources.
- `:KotlinSourcesClear` — clear the extracted jar cache.

## Requirements

- Neovim ≥ 0.10
- [`ripgrep`](https://github.com/BurntSushi/ripgrep) (`rg`), `unzip`, `find` on `PATH`
- (optional) [snacks.nvim] for the explorer integration (`<leader>ke`)
- (optional) a gradle wrapper / `gradle` / `make` / `manage.py` for the runners

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
    formatprg = "ktlint --format --stdin --log-level=none", -- whole-buffer formatter (<leader>cf)
    format_on_equal = false,                -- opt-in: also map `=` to whole-buffer format
    symbols = { icons = { --[[ class/interface/object/companion/fun/field ]] } },
    intellij_keymaps = false,               -- register IntelliJ maps in addition to the vim ones
    snacks_integration = true,              -- optional snacks.nvim explorer (see below)
    run = {
        height = 15,                        -- bottom terminal split height
        main_property = "mainClass",        -- gradle -P property for run_file (see Runners)
    },
    keymaps = {
        goto_definition    = "gd",
        hover              = "K",
        signature_help     = "gK",
        find_usages        = { "gu", "grr" },
        rename             = "<leader>cr",
        rename_file        = "<leader>cR",
        format             = "<leader>cf",
        file_structure     = "<leader>cs",
        project_symbols    = "<leader>cS",
        reveal_in_explorer = "<leader>ke",
        alternate_file     = "<leader>ka",
        copy_fqname        = "<leader>kc",
        auto_import        = "<leader>ki",
        run_file           = "<leader>kr",
        run_project        = "<leader>kR",
        find_files         = "<leader><leader>",
    },
})
```

Set any keymap to `false` to disable it. Each value may be a single lhs or a
list of them. All maps are buffer-local to kotlin filetypes, so your normal LSP
maps (including `grr`) are untouched in other buffers. `<leader>cf` formats the
whole buffer via `formatprg`; `=` stays native unless `format_on_equal = true`.
Outline icons are nerd-font codicons — override `symbols.icons` with plain text
if you don't use a nerd font.

### IntelliJ keymaps

With `intellij_keymaps = true` these are added on kotlin buffers (on top of the
vim maps above):

| Key            | Action                                        |
| -------------- | --------------------------------------------- |
| `<C-n>`        | Find files (Telescope / snacks, best-effort)  |
| `<C-e>`        | Recent files                                  |
| `<S-F6>`       | Rename symbol                                  |
| `<C-A-l>`      | Format buffer                                  |
| `<C-S-t>`      | Alternate file (go to test)                    |
| `<M-CR>`       | Auto-import under cursor (Alt+Enter)           |
| `<C-/>`        | Toggle comment (built-in `gc`)                |
| `<S-F10>`      | Run project                                   |
| `<C-S-F10>`    | Run file                                       |
| `<C-S-->` / `<C-S-=>` | Collapse / expand all folds (`zM` / `zR`) |

Several of these (`<C-A-l>`, `<M-CR>`, `<C-/>`, `<C-S-...>`) depend on your
terminal actually emitting the sequence — they work in modern GUI terminals
(kitty, WezTerm, Ghostty) but may be silently dropped in a bare TTY.

### Runners

`<leader>kr` / `<leader>kR` (and `<C-S-F10>` / `<S-F10>`) open a bottom terminal
split. The runner walks up from the file to the nearest project root and picks:

1. `./gradlew run` (wrapper preferred), else `gradle run`
2. `make run`
3. `python3 manage.py runserver`

`run_file` additionally passes `-PmainClass=<package>.<File>Kt`. To make it run
*that* file's `main`, wire the property in your build once:

```kotlin
application { mainClass = providers.gradleProperty("mainClass").orElse("com.example.MainKt") }
```

Without that wiring it still runs the project's configured main. Change the
property name via `run.main_property`.

### snacks.nvim explorer (optional)

[snacks.nvim] is a **strictly optional** dependency — the plugin never requires
it at load time and works fully without it. When `snacks_integration = true`
(the default) it provides an IntelliJ-style explorer for Kotlin trees:

- **Compact middle packages** — `com/example/foo/bar` collapses to
  `com.example.foo.bar` like IntelliJ (toggle with `<leader>km`).
- **Kotlin-aware "add file"** (`a`) — seeds `package` + `class` from the dir.
- **Kotlin-aware rename** (`<leader>cR`) — renames the selected item and offers
  the module-scoped entity rename; unavailable while several items are selected.
- Recursive open/collapse (`zo`/`zO`/`zA`/`zR`), git stage (`<A-a>`), yank
  file(s) to the system clipboard (`Y`) — cross-platform (macOS `osascript`,
  Windows `Set-Clipboard`, Linux `wl-copy`/`xclip`/`xsel`).

Wire the explorer opts into your snacks config:

```lua
{
    "folke/snacks.nvim",
    opts = {
        picker = {
            sources = {
                explorer = require("kotlin-lite").explorer_opts(),
            },
        },
    },
}
```

`<leader>ke` reveals the current file. If snacks is not installed it shows a
polite warning; set `snacks_integration = false` to make it a silent no-op.

## Layout

```
lua/kotlin-lite/
├── init.lua      -- setup()/init(), autocmds, user commands
├── config.lua    -- defaults + option merging
├── jars.lua      -- *-sources.jar discovery, extraction, read-only cache
├── search.lua    -- ripgrep + Kotlin decl patterns + in-buffer search
├── actions.lua   -- gd / K / gK / gr / rename / rename-file / structure / symbols / alternate / fqname / auto-import / format
├── runner.lua    -- run_file / run_project (bottom terminal split)
├── keymaps.lua   -- buffer-local keymap attachment
└── snacks.lua    -- optional snacks.nvim explorer integration (loaded lazily)
plugin/kotlin-lite.lua  -- startup bootstrap
tests/                  -- fixtures + interactive harness + headless checks
```

See [`tests/README.md`](tests/README.md) to try it live or run the checks.

[snacks.nvim]: https://github.com/folke/snacks.nvim
