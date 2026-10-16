-- `it` in a lambda: declared by the lambda's `{`.

local h = require("helpers")
local actions = require("kotlin-lite.actions")
local highlight = require("kotlin-lite.highlight")

local FILE = "gd/lambda/ItLambda.kt"

local function on_it(needle, nth)
    h.open(FILE)
    h.cursor_at(needle, "it", nth)
end

-- line and column of the `{` of the lambda on the line with `needle`
local function brace(needle)
    local lnum = h.line_of(needle)
    return { lnum, vim.fn.getline(lnum):find("{", 1, true) - 1 }
end

local function float_on(needle)
    local shown
    h.stub(vim.lsp.util, "open_floating_preview", function(lines) shown = lines end)
    on_it(needle)
    actions.hover()
    h.wait(function() return shown ~= nil end)
    return shown
end

describe("it", function()
    after_each(h.reset)

    local jumps = {
        { "the enclosing lambda", "sumOf { it.millis }", "sumOf { it.millis }" },
        { "past a lambda with named params", "n + it.millis", "phases.forEach {" },
        { "past a lambda with a receiver", "println(it.millis)", "phases.forEach {" },
    }
    for _, c in ipairs(jumps) do
        local name, needle, target = unpack(c)
        it("gd: " .. name, function()
            on_it(needle)
            actions.goto_definition()
            assert.are.same(brace(target), vim.api.nvim_win_get_cursor(0))
        end)
    end

    it("K: the element type of a collection", function()
        assert.are.equal("it: Phase", float_on("sumOf { it.millis }")[1])
    end)

    it("K: the receiver of let", function()
        assert.are.equal("it: String", float_on("let { it.length }")[1])
    end)

    it("grt: the element type", function()
        on_it("sumOf { it.millis }")
        actions.goto_type_definition()
        h.wait(function() return vim.fn.line(".") ~= h.line_of("sumOf { it.millis }") end)
        assert.are.equal(h.line_of("class Phase"), h.cur_line())
    end)

    it("gu: only the same lambda's", function()
        on_it("n + it.millis")
        local want = { h.line_of("n + it.millis"), h.line_of("println(it.millis)") }
        actions.find_usages()
        h.wait(function() return #vim.fn.getqflist() > 0 end)
        assert.are.same(want, vim.tbl_map(function(item) return item.lnum end, vim.fn.getqflist()))
    end)

    it("highlight: only the same lambda's", function()
        on_it("sumOf { it.millis }")
        highlight.refresh(0)
        local marks = vim.api.nvim_buf_get_extmarks(0, highlight.ns, 0, -1, {})
        assert.are.same({ h.line_of("sumOf { it.millis }") }, vim.tbl_map(function(m) return m[2] + 1 end, marks))
    end)

    it("rename: names the parameter", function()
        h.stub(vim.ui, "input", function(_, cb) cb("phase") end)
        on_it("sumOf { it.millis }")
        actions.rename()
        h.wait(function() return vim.fn.getline(h.line_of("fun total")):find("phase") ~= nil end)
        assert.are.equal("    fun total() = phases.sumOf { phase -> phase.millis }", vim.fn.getline(h.line_of("fun total")))
    end)
end)
