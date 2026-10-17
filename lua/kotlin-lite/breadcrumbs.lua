-- The classes and the member the cursor is in, for a statusline / winbar:
-- "Counter › Companion › zero".

local scope = require("kotlin-lite.scope")
local calls = require("kotlin-lite.calls")

local M = {}

M.separator = " › "

local scans = {} -- buf -> { tick, sc }

vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = vim.api.nvim_create_augroup("kotlin-lite-breadcrumbs", { clear = true }),
    callback = function(ev) scans[ev.buf] = nil end,
})

-- the buffer's scan, redone after an edit; while typing the last one will do
local function scan(buf)
    local s = scans[buf]
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    if not s or (s.tick ~= tick and not vim.api.nvim_get_mode().mode:match("^[iR]")) then
        s = { tick = tick, sc = scope.scan(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) }
        scans[buf] = s
    end
    return s.sc
end

-- the class whose header (`class X(...) : Y {`) `p` is in
local function header_at(sc, p)
    local best
    for _, b in ipairs(sc.blocks) do
        if b.kind == "type" and b.head_start <= p and p < b.open
            and (not best or b.depth > best.depth) then
            best = b
        end
    end
    return best
end

-- the names at line `l`, taken as a whole
local function names_at(sc, l, java)
    local line = sc.mask[l] or ""
    local first = line:find("%S")
    local header = header_at(sc, scope.key(l, #line))
    if header then
        local names = calls.types(sc, header.open + 1)
        if scope.unkey(header.head_start) ~= l then
            names[#names + 1] = calls.member_on(line)
        end
        return names
    end
    if not first then
        local p = scope.key(l, 0)
        local b = scope.innermost(sc, p)
        if b.kind == "type" or b == sc.root then return calls.types(sc, p) end
        return calls.path(sc, l, 0, java)
    end
    if line:sub(first, first) == "}" then
        -- just inside the block it closes
        return calls.path(sc, l, first - 2, java)
    end
    return calls.path(sc, l, #line, java)
end

--- for the current window; "" outside kotlin / java
function M.get()
    local buf = vim.api.nvim_get_current_buf()
    local ft = vim.bo[buf].filetype
    local java = ft == "java"
    if not java and not vim.tbl_contains(require("kotlin-lite.config").options.filetypes, ft) then
        return ""
    end
    local names = names_at(scan(buf), vim.api.nvim_win_get_cursor(0)[1], java)
    return table.concat(names, M.separator)
end

return M
