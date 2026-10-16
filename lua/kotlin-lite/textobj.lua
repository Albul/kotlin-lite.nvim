-- Text objects from scope blocks: af / if (fun), ac / ic (class / object).

local scope = require("kotlin-lite.scope")

local M = {}

--- Linewise: the innermost `kind` block ("fun" | "type"), or (`inner`) its body.
function M.select(kind, inner)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local sc = scope.scan(lines)
    local cur = vim.api.nvim_win_get_cursor(0)
    local p = scope.key(cur[1], cur[2])
    local block
    for _, b in ipairs(scope.enclosing(sc, p)) do
        if b.kind == kind then block = b break end
    end
    if not block or block.close == math.huge then return end
    local first, last = scope.unkey(block.head_start), scope.unkey(block.close)
    if inner then
        first, last = scope.unkey(block.open) + 1, last - 1
        if first > last then return end
    end
    if vim.fn.mode():find("^[vV\22]") then vim.cmd("normal! \27") end
    vim.api.nvim_win_set_cursor(0, { first, 0 })
    vim.cmd("normal! V")
    vim.api.nvim_win_set_cursor(0, { last, 0 })
end

function M.attach(buf)
    for lhs, spec in pairs({ af = { "fun", false }, ["if"] = { "fun", true },
        ac = { "type", false }, ic = { "type", true } }) do
        vim.keymap.set({ "o", "x" }, lhs, function() M.select(spec[1], spec[2]) end, {
            buffer = buf, silent = true, desc = "kotlin-lite: " .. lhs .. " text object",
        })
    end
end

return M
