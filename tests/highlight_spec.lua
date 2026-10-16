-- Highlighting the occurrences of the symbol under the cursor (by scope).

local h = require("helpers")
local highlight = require("kotlin-lite.highlight")

local SCOPED = "gd/scope/Scoped.kt"

-- refresh on the `nth` `word` of the line with `needle` -> sorted "line:col"
-- of the highlights, the line of the one marked as the declaration
local function marks(needle, word, nth)
    h.open(SCOPED)
    h.cursor_at(needle, word, nth)
    highlight.refresh(0)
    local out, decl = {}, nil
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, highlight.ns, 0, -1, { details = true })) do
        out[#out + 1] = (m[2] + 1) .. ":" .. m[3]
        if m[4].hl_group == "LspReferenceWrite" then decl = m[2] + 1 end
    end
    table.sort(out, function(a, b) return tonumber(a:match("^%d+")) < tonumber(b:match("^%d+")) end)
    return table.concat(out, " "), decl
end

describe("reference highlight", function()
    after_each(h.reset)

    local cases = {
        { "local: its scope, not the shadowed ones", "val count = 2", "count", 1, "21:12 26:16", 21 },
        { "inner shadowing local", "// inner", "count", 1, "23:16 24:20", 23 },
        { "member: not locals, comments or strings; templates count", "val count = 1", "count", 1,
            "4:8 13:15 30:16 40:16 50:33", 4 },
        { "param", "println(local * 2)", "local", 1, "16:14 17:16", 16 },
    }
    for _, c in ipairs(cases) do
        local name, needle, word, nth, want, decl = unpack(c)
        it(name, function()
            local got, d = marks(needle, word, nth)
            assert.are.equal(want, got)
            assert.are.equal(decl, d)
        end)
    end

    it("nothing in a comment", function()
        assert.are.equal("", (marks("val count = 7", "count")))
    end)

    it("cleared when the cursor leaves the word", function()
        marks("val count = 2", "count")
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        highlight.refresh(0)
        assert.are.same({}, vim.api.nvim_buf_get_extmarks(0, highlight.ns, 0, -1, {}))
    end)
end)

describe("]r / [r (next / previous occurrence)", function()
    after_each(function()
        vim.o.wrapscan = true
        h.reset()
    end)

    local function jump(needle, word, count, nth)
        h.open(SCOPED)
        h.cursor_at(needle, word, nth)
        highlight.jump(count)
        local cur = vim.api.nvim_win_get_cursor(0)
        return cur[1] .. ":" .. cur[2]
    end

    it("next", function()
        assert.are.equal("13:15", jump("val count = 1", "count", 1))
    end)

    it("a count skips", function()
        assert.are.equal("30:16", jump("val count = 1", "count", 2))
    end)

    it("previous wraps around", function()
        assert.are.equal("50:33", jump("val count = 1", "count", -1))
    end)

    it("stays at the end without 'wrapscan'", function()
        vim.o.wrapscan = false
        assert.are.equal("50:33", jump("count is ${count}", "count", 1, 2))
    end)

    it("a local: within its scope", function()
        assert.are.equal("21:12", jump("println(count) // outer", "count", 1))
    end)

    it("from inside the word", function()
        h.open(SCOPED)
        h.cursor_at("return count", "count")
        vim.cmd("normal! ll")
        highlight.jump(1)
        assert.are.same({ 30, 16 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("highlights at once", function()
        jump("val count = 1", "count", 1)
        assert.are.equal(5, #vim.api.nvim_buf_get_extmarks(0, highlight.ns, 0, -1, {}))
    end)
end)
