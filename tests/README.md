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

[minit]: https://github.com/folke/lazy.nvim/blob/main/lua/lazy/minit.lua
