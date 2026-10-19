-- Grep-based Kotlin navigation without an LSP. plugin/kotlin-lite.lua calls
-- init() on startup (zero-config); setup(opts) overrides defaults.
-- Requires: ripgrep, unzip, find.

local M = {}

local initialized = false
local started = false

local GRADLE_MARKERS = { "gradlew", "settings.gradle.kts", "settings.gradle",
    "build.gradle.kts", "build.gradle" }

-- gradle project root of `buf` (or of the cwd for an unnamed buffer)
local function gradle_root(buf)
    local name = vim.api.nvim_buf_get_name(buf or 0)
    return vim.fs.root((name ~= "" and name) or vim.fn.getcwd(), GRADLE_MARKERS)
end

-- The part that costs something (snacks probe, jar cache discovery), run once
-- on the first kotlin buffer or gradle project -- never on a plain startup.
local function start(root)
    if started then return end
    started = true
    local opts = require("kotlin-lite.config").options
    if opts.snacks_integration and pcall(require, "snacks") then
        local keymaps = require("kotlin-lite.keymaps")
        keymaps.attach_globals(keymaps.snacks_actions)
    end
    vim.schedule(function() require("kotlin-lite.fetch").auto_sync(root) end)
end

-- Treesitter folds of a buffer opened before the plugin was on 'runtimepath'
-- miss its queries/kotlin/folds.scm. Setting the options again drops nvim's
-- query cache and recomputes the folds; scheduled, as OptionSet doesn't fire
-- inside the autocmd that loads the plugin (lazy's VeryLazy).
local function refresh_folds()
    vim.schedule(function()
        vim.go.runtimepath = vim.go.runtimepath
        vim.go.foldminlines = vim.go.foldminlines
    end)
end

-- (re)register the FileType autocmd and attach to already-open buffers
local function register()
    local config = require("kotlin-lite.config")
    local keymaps = require("kotlin-lite.keymaps")

    local function attach(buf)
        start(gradle_root(buf))
        keymaps.attach(buf)
    end

    local group = vim.api.nvim_create_augroup("kotlin-lite-attach", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = config.options.filetypes,
        callback = function(ev) attach(ev.buf) end,
    })
    local open = false
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf)
            and vim.tbl_contains(config.options.filetypes, vim.bo[buf].filetype) then
            attach(buf)
            open = true
        end
    end
    if open then refresh_folds() end
end

-- one-time bootstrap: autocmds and user commands only (cheap, no disk scans)
function M.init()
    if initialized then return end
    initialized = true
    require("kotlin-lite.jars").setup()
    register()

    -- Project actions (run / sources / reveal) are global maps in a gradle
    -- project. Detect it from the current file (or cwd), retrying on BufEnter
    -- until found -- the file that reveals the project may be java, a build
    -- script, etc., not necessarily where nvim was started.
    local opts = require("kotlin-lite.config").options
    if opts.project_keymaps then
        local function try()
            local root = gradle_root(0)
            if not root then return false end
            start(root)
            local keymaps = require("kotlin-lite.keymaps")
            keymaps.attach_globals(keymaps.project_actions)
            return true
        end
        if not try() then
            local grp = vim.api.nvim_create_augroup("kotlin-lite-project", { clear = true })
            vim.api.nvim_create_autocmd("BufEnter", {
                group = grp,
                callback = function()
                    if try() then vim.api.nvim_del_augroup_by_id(grp) end
                end,
            })
        end
    end

    vim.api.nvim_create_user_command("KotlinSources", function()
        start(gradle_root(0))
        require("kotlin-lite.jars").pick_sources_jar()
    end, { desc = "kotlin-lite: extract a *-sources.jar for navigation" })

    vim.api.nvim_create_user_command("KotlinSourcesSync", function()
        local fetch = require("kotlin-lite.fetch")
        local name = vim.api.nvim_buf_get_name(0)
        local root = fetch.build_root(name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd())
        if not root then
            return vim.notify("kotlin-lite: not in a gradle build", vim.log.levels.WARN)
        end
        fetch.sync(root)
    end, { desc = "kotlin-lite: extract the sources of every library on the build's classpaths" })

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
