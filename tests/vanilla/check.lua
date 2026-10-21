-- Assertions for tests/vanilla/run.sh, run inside the nvim it starts (-c).
-- _G.SMOKE (set with --cmd, before any config) holds the scenario and the
-- notifications seen since startup.

local S = _G.SMOKE
local failed = 0

local function check(ok, what, detail)
    io.stdout:write(("  %s %s%s\n"):format(ok and "ok  " or "FAIL", what,
        (not ok and detail) and (" -- " .. detail) or ""))
    if not ok then failed = failed + 1 end
end

local function nmap(lhs, buffer)
    local m = vim.fn.maparg(lhs, "n", false, true)
    if vim.tbl_isempty(m) or (buffer ~= nil and (m.buffer == 1) ~= buffer) then return nil end
    return m
end

io.stdout:write(("[%s] nvim %s, mapleader %q\n"):format(S.scenario,
    tostring(vim.version()), vim.g.mapleader or "\\"))

check(vim.g.loaded_kotlin_lite == true, "plugin/kotlin-lite.lua sourced")
if S.from then
    local init = vim.api.nvim_get_runtime_file("lua/kotlin-lite/init.lua", true)
    check(#init == 1 and init[1]:find(S.from) ~= nil, "loaded from " .. S.from,
        table.concat(init, ", "))
end
check(vim.fn.exists(":KotlinSourcesSync") == 2, ":KotlinSourcesSync defined")
check(not pcall(require, "snacks") and not pcall(require, "telescope"),
    "no snacks / telescope on 'runtimepath'")

local buf = vim.api.nvim_get_current_buf()
check(vim.bo[buf].filetype == "kotlin", "Main.kt has filetype kotlin", vim.bo[buf].filetype)
check(vim.b[buf].kotlin_lite_attached == true, "attached to the kotlin buffer")

local gd = nmap("gd", true)
check(gd ~= nil and (gd.desc or ""):find("kotlin%-lite") ~= nil, "gd mapped buffer-locally")
-- spelled out with the scenario's leader, so a hard-coded one would show
local leader = vim.g.mapleader or "\\"
check(nmap(leader .. "kc", true) ~= nil, ("<leader>kc mapped as %q"):format(leader .. "kc"))

-- gd: `Circle` on Main.kt:5 -> class Circle in Geometry.kt:8
if gd then
    vim.api.nvim_win_set_cursor(0, { 5, 17 })
    local ok, err = pcall(gd.callback)
    check(ok, "gd runs", err)
    vim.wait(5000, function()
        return vim.api.nvim_buf_get_name(0):find("Geometry%.kt$") ~= nil
    end, 20)
    local name = vim.fs.basename(vim.api.nvim_buf_get_name(0))
    local row = vim.api.nvim_win_get_cursor(0)[1]
    check(name == "Geometry.kt" and row == 8, "gd on Circle lands on Geometry.kt:8",
        ("%s:%d"):format(name, row))
    vim.cmd("buffer " .. buf)
end

-- with no picker plugin, lists fall back to vim.ui.select
local go = nmap("gO", true)
if go then
    local seen
    local select = vim.ui.select
    vim.ui.select = function(items) seen = items end
    local ok, err = pcall(go.callback)
    vim.ui.select = select
    check(ok and seen ~= nil and #seen > 0, "gO (file structure) falls back to vim.ui.select",
        err or ("items: " .. tostring(seen and #seen)))
else
    check(false, "gO mapped")
end

if S.gradle then
    -- a buffer in a gradle project brings the global <leader>k project maps;
    -- not a .kts one, that is kotlin and gets them buffer-locally anyway
    vim.cmd("edit " .. vim.fn.fnameescape(S.gradle .. "/gradle.properties"))
    vim.wait(200)
    check(nmap("<leader>kR", false) ~= nil, "<leader>kR global in a gradle project")
end

-- language.add returns nil, err (0.11+) or throws (0.10) when there is none
local ok_add, added = pcall(vim.treesitter.language.add, "kotlin")
local has_parser = ok_add and added == true
io.stdout:write(("  info kotlin treesitter parser: %s\n"):format(has_parser and "yes" or "no"))

vim.wait(300) -- let scheduled work (refresh_queries, highlight timers) run
local errors = vim.tbl_filter(function(n) return n.level >= vim.log.levels.ERROR end, S.notes)
check(#errors == 0, "no error notifications", errors[1] and errors[1].msg)
check(vim.v.errmsg == "", "v:errmsg empty", vim.v.errmsg)

io.stdout:write(failed == 0 and "  passed\n" or ("  %d failed\n"):format(failed))
vim.cmd(failed == 0 and "qall!" or "cquit!")
