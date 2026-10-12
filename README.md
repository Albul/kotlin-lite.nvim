# kotlin-lite.nvim

Grep-based Kotlin navigation for Neovim — **no LSP required**. It uses `ripgrep`
plus Kotlin-aware regex heuristics to give you IntelliJ-style motions for `.kt` /
`.kts` files. Great for large Kotlin/Android codebases where a full LSP is slow
or unavailable, and for reading library sources extracted from `*-sources.jar`.

## Features

| Default keymap        | Action                                                                 |
| --------------------- | ---------------------------------------------------------------------- |
| `gd`                  | Go to definition — current buffer first (locals, params, lambda params, for-vars, properties, funs, classes), then project-wide + extracted jar sources. Multiple hits open a picker with preview: `expect`/`actual` · signature · source set · module or `artifact version` · `file:line` (older versions of the same jar are hidden). On an `import` line it resolves through the full path (incl. nested classes and `as` aliases) and jumps without a picker |
| `K`                   | Hover: declaration + KDoc in a floating window                         |
| `gK`                  | Signature of the function whose call the cursor is inside              |
| `gu` / `grr`          | Find usages → quickfix panel at the bottom                             |
| `<leader>cr`          | Rename symbol: project-wide word search & replace with confirmation    |
| `<leader>cR`          | Rename file; for a same-named top-level `class`/`interface`/`object`/`fun` it offers a module-scoped symbol rename |
| `<leader>cs`          | File structure outline — top-level decls & class members (incl. private/protected/internal, marked with a UML sigil), with kind icons (IntelliJ `Ctrl+F12`) |
| `<leader>cS`          | Go to symbol — live-search picker over top-level classes/objects/interfaces/enums & functions (IntelliJ `Ctrl+N`) |
| `<leader><leader>`    | Go to file (Telescope / snacks, best-effort)                           |
| `<leader>ke`          | Reveal current file in the [snacks.nvim] explorer (IntelliJ `Alt+F1`)  |
| `<leader>ka`          | Alternate file: `X.kt` ⇄ `XTest.kt` — searches the module for the `Test`-suffixed counterpart wherever it lives, and offers to scaffold it if absent |
| `<leader>cf`          | Format the whole buffer via `formatprg` (ktlint by default)            |
| `<leader>kc`          | Copy the file's fully-qualified name (`package.ClassName`) to the `+` register |
| `<leader>ki`          | Auto-import the symbol under the cursor (rg for the definition, picker if ambiguous) |
| `<leader>kr`          | Run the current file (needs a top-level `main()`) in a bottom terminal split |
| `<leader>kR`          | Run the project in a bottom terminal split                             |
| `<leader>kt`          | Test the current file (`gradle test --tests <FQCN>`)                   |
| `<leader>kT`          | Test the project (module picker if multi-module)                       |

Commands:

- `:KotlinSources` (`<leader>ks`) — pick a `*-sources.jar` from `~/.gradle` /
  `~/.m2` to extract so navigation reaches into library sources. Only the newest
  version of each artifact is listed, extracted ones first.
- `:KotlinSourcesClear` — clear the extracted jar cache.

On startup the newest cached sources for common libraries (kotlin stdlib,
coroutines, serialization, test libs; androidx + Compose in Android projects) are
extracted in the background — customize via `essentials`, disable with
`auto_extract = false`.

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
    -- Load eagerly so the `<leader>k` project menu works before you open a .kt
    -- file. Use `ft = { "kotlin" }` instead if you don't need that.
    event = "VeryLazy",
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
    auto_extract = true,                    -- extract essential library sources on startup
    project_keymaps = true,                 -- expose project-level maps globally in a gradle project
    -- essentials = { kotlin = {...}, android = {...} }, -- artifact names to auto-extract
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
        sources            = "<leader>ks",
        toggle_compact     = "<leader>km",
        find_files         = "<leader><leader>",
    },
})
```

Set any keymap to `false` to disable it. Each value may be a single lhs or a
list of them. Most maps are buffer-local to kotlin filetypes, so your normal LSP
maps (including `grr`) are untouched elsewhere. The exceptions are registered
globally so they work without a `.kt` buffer (and inside the snacks explorer):
`<leader>kR` / `<leader>ks` / `<leader>ke` in a gradle project
(`project_keymaps = false` to opt out), and `<leader>km` (compact packages)
whenever snacks is integrated. `<leader>cf` formats the whole buffer via
`formatprg`; `=` stays native unless `format_on_equal = true`. Outline icons are
nerd-font codicons — override `symbols.icons` with plain text if you don't use a
nerd font. Live search in the `<leader>cs`/`<leader>cS` pickers is
case-insensitive.

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
(the default) it adds an IntelliJ-style explorer for Kotlin trees, with these
keys in the explorer window:

| Key           | Action                                                               |
| ------------- | ------------------------------------------------------------------- |
| `<leader>km`  | Toggle **compact middle packages** (`com/example/foo` → `com.example.foo`); also global |
| `a`           | Add file/dir — Kotlin-aware, seeds `package` + `class` from the directory |
| `<leader>cR`  | Kotlin-aware rename (offers the module-scoped entity rename; disabled for a multi-selection) |
| `Y`           | Yank file(s) to the system clipboard (macOS `osascript`, Windows `Set-Clipboard`, Linux `wl-copy`/`xclip`/`xsel`) |
| `zo` / `zO`   | Open directory (one level / recursively)                            |
| `zA` / `zM`   | Toggle recursively / close all                                      |
| `zR`          | Open all directories                                                |
| `<A-a>`       | Git: add to index                                                   |

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

### Testing

`<leader>kt` / `<leader>kT` run gradle tests in a bottom terminal. A temporary
`--init-script` (no project changes) forces per-test `PASSED`/`FAILED` logging
and a total line; on finish a summary is notified and failed tests are parsed
from the JUnit XML into the quickfix list. The task is inferred (no slow gradle
query) from the test file's **source set** — `src/commonTest` or `src/jvmTest` →
`jvmTest`, `src/test` → `test` — falling back to project structure (KMP →
`jvmTest`, else `test`, which on Android covers all unit-test variants). Reruns
are forced by clearing the module's `build/test-results` (no dependency on a
`clean<Task>`). Override via `test = { task, rerun, quickfix }`.

## Layout

```
lua/kotlin-lite/
├── init.lua      -- setup()/init(), autocmds, user commands
├── config.lua    -- defaults + option merging
├── jars.lua      -- *-sources.jar discovery, extraction, read-only cache
├── search.lua    -- ripgrep + Kotlin decl patterns + in-buffer search
├── defs.lua      -- gd picker rows: newest jar version only, expect/actual columns
├── actions.lua   -- gd / K / gK / gr / rename / rename-file / structure / symbols / alternate / fqname / auto-import / format
├── runner.lua    -- run + test (bottom terminal, gradle init-script, quickfix)
├── keymaps.lua   -- buffer-local + global keymap attachment
├── picker.lua    -- case-insensitive list picker (snacks, else vim.ui.select)
└── snacks.lua    -- optional snacks.nvim explorer integration (loaded lazily)
plugin/kotlin-lite.lua  -- startup bootstrap
tests/                  -- fixtures + interactive harness + headless checks
```

See [`tests/README.md`](tests/README.md) to try it live or run the checks.

[snacks.nvim]: https://github.com/folke/snacks.nvim
