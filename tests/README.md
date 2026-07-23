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

## 2. Automated checks

```sh
tests/run.sh
# or:
nvim --headless -u tests/minimal_init.lua -l tests/run.lua
```

`run.lua` drives the real actions (`goto_definition`, `find_usages`) against the
fixtures and asserts the outcomes. It prints `ok` / `FAIL` per check and exits
non-zero if anything fails, so it can gate CI.

Requires `rg` (ripgrep) on `PATH`, same as the plugin itself.
