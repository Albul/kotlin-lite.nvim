-- Breadcrumbs for the statusline: the classes and the member the cursor is in.

local h = require("helpers")
local breadcrumbs = require("kotlin-lite.breadcrumbs")

local function at(lnum)
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    return breadcrumbs.get()
end

describe("breadcrumbs", function()
    before_each(function() h.open("calls/Calls.kt") end)
    after_each(h.reset)

    it("names the classes and the member", function()
        assert.are.equal("Counter › start", at(6))
        assert.are.equal("Counter › Companion › zero", at(22))
        assert.are.equal("main", at(27))
        assert.are.equal("tally", at(3))
    end)

    it("inside a lambda: the function it is in", function()
        assert.are.equal("Counter › bump", at(14))
        assert.are.equal("Counter › bump", at(15))
    end)

    it("on a declaration line: that declaration", function()
        assert.are.equal("Counter", at(5))
        assert.are.equal("Counter › init", at(8))
        assert.are.equal("Counter › bump", at(12))
        assert.are.equal("Counter › Companion", at(21))
    end)

    it("on a closing brace: the block it closes", function()
        assert.are.equal("Counter › init", at(10))
        assert.are.equal("Counter › bump", at(16))
        assert.are.equal("Counter › Companion", at(23))
        assert.are.equal("Counter", at(24))
        assert.are.equal("main", at(28))
    end)

    it("between members: only the classes", function()
        assert.are.equal("Counter", at(7))
        assert.are.equal("Counter", at(17))
        assert.are.equal("", at(4))
        assert.are.equal("", at(25))
        assert.are.equal("", at(1))
    end)

    it("an expression body continued on the next line", function()
        assert.are.equal("Counter › twice", at(19))
    end)

    it("follows edits", function()
        vim.api.nvim_buf_set_lines(0, 25, 26, false, { "fun start() {" })
        assert.are.equal("start", at(27))
    end)

    it("extension functions on a generic receiver", function()
        h.open("breadcrumbs/Scene.kt")
        assert.are.equal("second", at(3))
        assert.are.equal("Strategy › calculate", at(6))
        assert.are.equal("Strategy › calculate", at(7))
    end)

    it("a class header and its constructor properties", function()
        h.open("breadcrumbs/Scene.kt")
        assert.are.equal("Scene", at(11))
        assert.are.equal("Scene › key", at(12))
        assert.are.equal("Scene › entry", at(13))
        assert.are.equal("Scene", at(14))
        assert.are.equal("Scene › content", at(15))
    end)

    it("empty in other filetypes", function()
        vim.bo.filetype = "lua"
        assert.are.equal("", at(6))
    end)
end)
