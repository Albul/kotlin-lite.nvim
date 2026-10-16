-- af / if / ac / ic: function and class text objects from scope blocks.

local h = require("helpers")

local SCOPED = "gd/scope/Scoped.kt"

-- select `obj` with the cursor on line `lnum` -> first, last line selected
local function sel(lnum, obj)
    h.open(SCOPED)
    vim.api.nvim_win_set_cursor(0, { lnum, 8 })
    vim.cmd("normal v" .. obj)
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    vim.cmd("normal! \27")
    return math.min(a, b), math.max(a, b)
end

describe("text objects", function()
    before_each(function() require("kotlin-lite.config").setup({ textobjects = true }) end)
    after_each(h.reset)

    local cases = {
        { "af: the fun", 8, "af", 6, 9 },
        { "if: its body", 8, "if", 7, 8 },
        { "af from a lambda inside: the enclosing fun", 24, "af", 20, 27 },
        { "ac: the class", 8, "ac", 3, 55 },
        { "ic: the class body", 8, "ic", 4, 54 },
    }
    for _, c in ipairs(cases) do
        local name, lnum, obj, first, last = unpack(c)
        it(name, function()
            assert.are.same({ first, last }, { sel(lnum, obj) })
        end)
    end

    it("as an operator target: daf", function()
        h.open(SCOPED)
        local n = vim.api.nvim_buf_line_count(0)
        vim.api.nvim_win_set_cursor(0, { 8, 8 })
        vim.cmd("normal daf")
        assert.are.equal(n - 4, vim.api.nvim_buf_line_count(0))
        assert.are.equal("", vim.api.nvim_buf_get_lines(0, 5, 6, false)[1])
    end)

    it("off by default", function()
        require("kotlin-lite.config").setup({})
        h.open("Main.kt")
        assert.are.equal("", vim.fn.maparg("af", "o"))
    end)
end)
