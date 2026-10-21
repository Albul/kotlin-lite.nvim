# kotlin-lite tests

Two ways to exercise the plugin against real Kotlin files.

## 1. Try it live (interactive)

Open a fixture with *only* this plugin loaded and use the keymaps:

```sh
nvim -u tests/minimal_init.lua tests/fixtures/Main.kt
```

Then, inside Neovim:

| On word              | Key  | Expected                                            |
| -------------------- | ---- | --------------------------------------------------- |
| `radius` (line 5)    | `gd` | jumps up to `val radius = 2.0` in the same buffer   |
| `Circle` (line 5)    | `gd` | jumps to `class Circle` in `Geometry.kt`            |
| `area`               | `gr` | quickfix at the bottom with all usages              |
| `Circle`             | `K`  | floating window with the declaration + KDoc         |
| inside `area( … )`   | `gK` | floating window with the function signature         |
| `Circle` (line 5)    | `<leader>ki` | inserts `import fixtures.Circle`            |
| anywhere             | `<leader>kc` | copies `fixtures.Main` to the `+` register  |

`tests/fixtures/src/{main,test}/kotlin/com/example/` holds `Sample.kt` /
`SampleTest.kt` for the alternate-file toggle (`<leader>ka`).

Drop your own `.kt` files into `tests/fixtures/` and navigate around them.

## 2. Automated checks (busted)

```sh
tests/run.sh                          # all specs
tests/run.sh --filter gri             # tests whose full name matches a Lua pattern
tests/run.sh tests/impl_spec.lua      # one file
tests/run.sh --offline                # skip the plugin update check (faster)
tests/run.sh -o TAP                   # any other busted option / reporter
```

`run.sh` runs `nvim -l tests/minit.lua --busted`: [`lazy.minit`][minit]
installs busted (via hererocks, Lua 5.1) into `./.tests` on the first run,
loads only this plugin and runs busted over `tests/*_spec.lua` (see `.busted`).
Exits non-zero on any failure, so it can gate CI.

Layout: one spec file per area (`definition_spec.lua`, `impl_spec.lua`,
`autoimport_spec.lua`, ...), `describe` per feature, `it` per behavior.
`helpers.lua` holds the shared bits: `open()` a fixture, `cursor_at()`,
`wait()` for async results, `stub()` / `capture_select()` / `capture_notify()`,
and `reset()` (use it as `after_each`) to revert stubs and wipe buffers.

Requirements:
- `rg` (ripgrep) on `PATH`, same as the plugin itself;
- `git`, `python3` and a C compiler for the one-time hererocks build, plus
  readline headers (`libreadline-dev` / `readline-devel`).

## 4. Without lazy.nvim (vanilla smoke test)

```sh
tests/vanilla/run.sh                  # with the nvim on PATH
tests/vanilla/docker.sh               # in Docker: v0.10.4, v0.11.7, v0.12.6
tests/vanilla/docker.sh v0.12.6 nightly
```

Installs the plugin in a throwaway XDG home, with no other plugin, no snacks /
Telescope and no kotlin treesitter parser, and runs it three times: as a
native package (`pack/smoke/start`) with no `init.lua` at all (default `\`
leader); as a native package with an `init.lua` that sets `mapleader = " "`
and calls `setup({...})`; and, on 0.12+, installed by `vim.pack.add()` from a
git snapshot of the working tree (uncommitted changes included). Each time it
checks that the plugin loads and attaches, the `<leader>` maps follow
`mapleader`, `gd` jumps, `gO` falls back to `vim.ui.select`, and nothing
errors; the last two also check the global `<leader>k` maps in a gradle
project (`tests/vanilla/check.lua`). Exits non-zero on any failure.

[minit]: https://github.com/folke/lazy.nvim/blob/main/lua/lazy/minit.lua
