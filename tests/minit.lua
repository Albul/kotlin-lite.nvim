#!/usr/bin/env -S nvim -l
-- Test bootstrap: lazy.nvim installs busted (via hererocks) into ./.tests and
-- loads only this plugin, then runs busted over tests/*_spec.lua.
--
--     tests/run.sh                       -- all specs
--     tests/run.sh --filter gri          -- by test name
--     tests/run.sh tests/impl_spec.lua   -- one file
--
-- See tests/README.md.

vim.env.LAZY_STDPATH = ".tests"

local lazy_path = vim.env.LAZY_PATH or vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if vim.fn.isdirectory(lazy_path) == 1 then
    vim.env.LAZY_PATH = lazy_path
    loadfile(lazy_path .. "/bootstrap.lua")()
else
    load(vim.fn.system("curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"),
        "bootstrap.lua")()
end

require("lazy.minit").setup({
    spec = {
        {
            dir = vim.uv.cwd(),
            config = function()
                -- isolate from the user's extracted jar sources: an empty temp
                -- cache and no auto-extract (set on the defaults too, so
                -- config.setup({}) in a test keeps them)
                local config = require("kotlin-lite.config")
                config.defaults.cache_dir = vim.fn.tempname()
                config.defaults.auto_extract = false
                require("kotlin-lite").setup({})
                require("kotlin-lite.jars").scan_cache()
            end,
        },
    },
})
