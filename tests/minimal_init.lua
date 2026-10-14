-- Minimal Neovim config that loads *only* kotlin-lite from this repo.
--
-- Interactive use (open a fixture and try gd / gr / K / gK live):
--     nvim -u tests/minimal_init.lua tests/fixtures/Main.kt
--
-- Automated runs use tests/minit.lua + busted instead (see tests/README.md).

local this = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(this, ":p:h:h") -- tests/ -> repo root

vim.opt.runtimepath:prepend(repo)
vim.opt.swapfile = false
vim.opt.ignorecase = false -- Kotlin identifiers are case-sensitive

-- Load the plugin (idempotent with plugin/kotlin-lite.lua auto-sourcing).
require("kotlin-lite").setup()
