-- Grep-based Kotlin navigation without an LSP. plugin/kotlin-lite.lua calls
-- init() on startup (zero-config); setup(opts) overrides defaults.
-- Requires: ripgrep, unzip, find.

local M = {}

local initialized = false

-- (re)register the FileType autocmd and attach to already-open buffers
local function register()
    local config = require("kotlin-lite.config")
    local keymaps = require("kotlin-lite.keymaps")

    local group = vim.api.nvim_create_augroup("kotlin-lite-attach", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = config.options.filetypes,
        callback = function(ev) keymaps.attach(ev.buf) end,
    })
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf)
            and vim.tbl_contains(config.options.filetypes, vim.bo[buf].filetype) then
            keymaps.attach(buf)
        end
    end
end

-- one-time bootstrap: jar cache, autocmds, user commands
function M.init()
    if initialized then return end
    initialized = true
    require("kotlin-lite.jars").setup()
    register()

    -- deferred so startup isn't blocked (the find + unzip are async anyway)
    vim.schedule(function() require("kotlin-lite.jars").auto_extract() end)

    vim.api.nvim_create_user_command("KotlinSources", function()
        require("kotlin-lite.jars").pick_sources_jar()
    end, { desc = "kotlin-lite: extract a *-sources.jar for navigation" })

    vim.api.nvim_create_user_command("KotlinSourcesClear", function()
        require("kotlin-lite.jars").clear()
    end, { desc = "kotlin-lite: clear the extracted jar cache" })
end

-- snacks.nvim explorer opts (compact middle packages + kotlin-aware actions).
-- Merge into your snacks config: picker.sources.explorer.
function M.explorer_opts()
    return require("kotlin-lite.snacks").explorer_opts()
end

-- apply user options; re-applies keymaps/filetypes if already initialized
function M.setup(opts)
    require("kotlin-lite.config").setup(opts)
    if initialized then
        register()
    else
        M.init()
    end
end

return M
