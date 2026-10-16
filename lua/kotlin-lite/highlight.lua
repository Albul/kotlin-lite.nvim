-- Occurrences of the symbol under the cursor, by scope (LSP documentHighlight).

local scope = require("kotlin-lite.scope")
local resolve = require("kotlin-lite.resolve")

local M = {}

M.ns = vim.api.nvim_create_namespace("kotlin-lite-references")

-- the last scan, reused while the buffer is unchanged
local last = {}

local function base_of(buf)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    if last.buf ~= buf or last.tick ~= tick then
        last = { buf = buf, tick = tick, base = resolve.base(buf) }
    end
    return last.base
end

local function key_of(d)
    return d and scope.key(d.lnum, d.col)
end

--- occurrences of the symbol under the cursor: { lnum, s, e, decl }, in order
local function occurrences(buf)
    local cur = vim.api.nvim_win_get_cursor(0)
    local base = base_of(buf)
    local ctx = resolve.context_at(base, cur[1], cur[2])
    if not ctx or not ctx.code or ctx.s > cur[2] or scope.KEYWORDS[ctx.word] then return {} end
    local sc, word = base.sc, ctx.word

    local decls = scope.decls(sc, word)
    local target
    if not ctx.recv then
        target = scope.visible(decls, ctx.pos, nil)
    end
    local lambda = word == "it" and not target and not ctx.recv and resolve.it_lambda(sc, ctx.pos)
    -- a member / top-level decl: its unqualified uses and every `x.word`
    local wide = not lambda and (not target or not resolve.is_local(sc, target))

    local out = {}
    local pat = "%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]"
    for l, m in ipairs(sc.mask) do
        local i = 1
        while true do
            local s, e = m:find(pat, i)
            if not s then break end
            i = e + 1
            local p = scope.key(l, s - 1)
            local keep
            if resolve.receiver(sc, l, s - 1) then
                keep = wide
            elseif lambda then
                keep = resolve.it_lambda(sc, p) == lambda
            else
                local v = scope.visible(decls, p, nil)
                keep = key_of(v) == key_of(target) or (wide and not target and not v)
            end
            if keep then
                out[#out + 1] = { lnum = l, s = s - 1, e = e, decl = target and p == key_of(target) }
            end
        end
    end
    return out
end

local function show(buf, occ)
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    for _, o in ipairs(occ) do
        vim.api.nvim_buf_set_extmark(buf, M.ns, o.lnum - 1, o.s, {
            end_col = o.e, hl_group = o.decl and "LspReferenceWrite" or "LspReferenceText",
        })
    end
end

function M.refresh(buf)
    buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
    show(buf, occurrences(buf))
end

--- ]r / [r: to the `count`th next (negative: previous) occurrence
function M.jump(count)
    local buf = vim.api.nvim_get_current_buf()
    local occ = occurrences(buf)
    if #occ == 0 then return end
    local cur = vim.api.nvim_win_get_cursor(0)
    local here = 1
    for i, o in ipairs(occ) do
        if o.lnum == cur[1] and o.s <= cur[2] and cur[2] < o.e then here = i end
    end
    local to = here + count
    if vim.o.wrapscan then
        to = (to - 1) % #occ + 1
    else
        to = math.max(1, math.min(#occ, to))
    end
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { occ[to].lnum, occ[to].s })
    show(buf, occ)
end

function M.attach(buf)
    local group = vim.api.nvim_create_augroup("kotlin-lite-references-" .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
        group = group, buffer = buf, callback = function() M.refresh(buf) end,
    })
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufLeave", "InsertEnter" }, {
        group = group, buffer = buf,
        callback = function()
            local word = vim.fn.expand("<cword>")
            if word ~= vim.b[buf].kotlin_lite_ref_word then
                vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
            end
            vim.b[buf].kotlin_lite_ref_word = word
        end,
    })
end

return M
