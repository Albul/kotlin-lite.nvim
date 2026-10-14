-- Shared helpers for the *_spec.lua files.
--
-- Requiring this module cd's into tests/fixtures: the plugin treats the cwd as
-- the project root, so rg scans the fixtures only. Busted loads every spec file
-- before running any, so the cd doesn't disturb test discovery.

local M = {}

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
M.fixtures = tests_dir .. "/fixtures"
vim.cmd.cd(M.fixtures)
vim.opt.swapfile = false
vim.opt.ignorecase = false -- Kotlin identifiers are case-sensitive
-- keep the reporter output clean; tests that check messages use capture_notify()
vim.notify = function() end

--- Edit a fixture (path relative to tests/fixtures) as a kotlin buffer.
function M.open(file)
    vim.cmd("edit! " .. vim.fn.fnameescape(M.fixtures .. "/" .. file))
    vim.bo.filetype = "kotlin"
end

--- 1-based line number of the first line containing literal `needle`.
function M.line_of(needle)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        if l:find(needle, 1, true) then return i end
    end
    error("line not found: " .. needle, 2)
end

--- Put the cursor on the first occurrence of `word` on line `lnum`.
function M.cursor_on(lnum, word)
    local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
    local col = line:find(word, 1, true)
    assert(col, ("'%s' not on line %d: %s"):format(word, lnum, line))
    vim.api.nvim_win_set_cursor(0, { lnum, col - 1 })
end

--- Cursor on `word` in the first line containing `needle`.
function M.cursor_at(needle, word)
    M.cursor_on(M.line_of(needle), word)
end

function M.bufname()
    return vim.api.nvim_buf_get_name(0)
end

--- Path of the current buffer relative to tests/fixtures.
function M.relname()
    local name = M.bufname()
    local prefix = M.fixtures .. "/"
    return name:sub(1, #prefix) == prefix and name:sub(#prefix + 1) or name
end

function M.cur_line()
    return vim.api.nvim_win_get_cursor(0)[1]
end

--- vim.wait with the suite's default timeout; returns whether `cond` held.
function M.wait(cond, ms)
    return (vim.wait(ms or 4000, cond, 20))
end

--- Wait until the current buffer leaves `start` (default: the current one).
function M.wait_jump(start, ms)
    start = start or M.bufname()
    return M.wait(function() return M.bufname() ~= start end, ms)
end

-------------------------------------------------------------------
-- stubs, reverted by M.reset()
-------------------------------------------------------------------
local stubs = {}

--- Replace `tbl[key]` with `fn` until the next M.reset().
function M.stub(tbl, key, fn)
    table.insert(stubs, { tbl, key, tbl[key] })
    tbl[key] = fn
end

--- Capture vim.ui.select calls without invoking the callback.
--- -> a table that gets `.list` / `.opts` once the picker is opened.
function M.capture_select()
    local cap = {}
    M.stub(vim.ui, "select", function(list, opts, _)
        cap.list, cap.opts = list, opts
    end)
    return cap
end

--- Picker rows rendered with the picker's own format_item.
function M.format_rows(cap)
    local fmt = cap.opts and cap.opts.format_item or tostring
    return vim.tbl_map(fmt, cap.list or {})
end

--- Capture vim.notify -> a table with `.msg` / `.level` of the last call.
function M.capture_notify()
    local cap = {}
    M.stub(vim, "notify", function(msg, level) cap.msg, cap.level = msg, level end)
    return cap
end

--- after_each: revert stubs, restore config, drop buffers / extra windows.
function M.reset()
    for i = #stubs, 1, -1 do
        local s = stubs[i]
        s[1][s[2]] = s[3]
    end
    stubs = {}
    require("kotlin-lite.config").setup({})
    vim.fn.setqflist({}, "r")
    vim.fn.settagstack(0, { items = {} }, "r")
    vim.cmd("silent! pclose | silent! cclose | silent! only")
    vim.cmd("silent! %bwipeout!")
end

return M
