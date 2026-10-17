-- Compiler errors / warnings in the output of a run -> vim.diagnostic.

local h = require("helpers")
local compiler = require("kotlin-lite.compiler")
local runner = require("kotlin-lite.runner")

local BROKEN = h.fixtures .. "/compile/src/Broken.kt"

describe("compiler.parse", function()
    it("kotlinc 2: e: file:///path:line:col message", function()
        assert.are.same({
            { filename = "/p/Foo.kt", lnum = 12, col = 5, severity = vim.diagnostic.severity.ERROR,
                message = "Unresolved reference 'bar'." },
        }, compiler.parse({ "e: file:///p/Foo.kt:12:5 Unresolved reference 'bar'." }))
    end)

    it("kotlinc 1: w: /path: (line, col): message", function()
        assert.are.same({
            { filename = "/p/Foo.kt", lnum = 3, col = 9, severity = vim.diagnostic.severity.WARN,
                message = "Variable 'x' is never used" },
        }, compiler.parse({ "w: /p/Foo.kt: (3, 9): Variable 'x' is never used" }))
    end)

    it("kotlinc on the command line: path:line:col: error: message, relative to the run's dir", function()
        assert.are.same({
            { filename = "/root/my dir/Foo.kt", lnum = 3, col = 12, severity = vim.diagnostic.severity.ERROR,
                message = "unresolved reference 'missing'." },
            { filename = "/abs/Bar.kt", lnum = 1, col = 2, severity = vim.diagnostic.severity.WARN,
                message = "unused" },
        }, compiler.parse({
            "my dir/Foo.kt:3:12: error: unresolved reference 'missing'.",
            "    return missing",
            "           ^^^^^^^",
            "/abs/Bar.kt:1:2: warning: unused",
        }, "/root"))
    end)

    it("a percent-encoded uri", function()
        assert.are.equal("/my dir/Foo.kt", compiler.parse({ "e: file:///my%20dir/Foo.kt:1:1 x" })[1].filename)
    end)

    it("terminal noise: carriage returns and colors", function()
        local got = compiler.parse({ "\27[31me: file:///p/Foo.kt:1:2 boom\27[0m\r" })
        assert.are.equal("boom", got[1].message)
    end)

    it("skips everything else", function()
        assert.are.same({}, compiler.parse({ "> Task :compileKotlin FAILED", "BUILD FAILED in 3s", "" }))
    end)
end)

describe("compiler.publish", function()
    after_each(function()
        compiler.publish({})
        h.reset()
    end)

    local function diags()
        local out = {}
        for _, d in ipairs(vim.diagnostic.get(vim.fn.bufnr(BROKEN), { namespace = compiler.ns })) do
            out[#out + 1] = (d.lnum + 1) .. ":" .. (d.col + 1) .. " " .. d.severity .. " " .. d.message
        end
        table.sort(out)
        return out
    end

    it("sets the diagnostics of the file, also when it isn't open", function()
        compiler.publish({
            { filename = BROKEN, lnum = 5, col = 12, severity = vim.diagnostic.severity.ERROR, message = "boom" },
        })
        assert.are.same({ "5:12 1 boom" }, diags())
    end)

    it("replaces the ones of the previous run", function()
        compiler.publish({
            { filename = BROKEN, lnum = 5, col = 12, severity = vim.diagnostic.severity.ERROR, message = "boom" },
        })
        compiler.publish({})
        assert.are.same({}, diags())
    end)
end)

describe("a run's compiler output", function()
    after_each(function()
        compiler.publish({})
        vim.cmd("silent! %bwipeout!")
        h.reset()
    end)

    it("ends up as diagnostics in the files, with a note", function()
        local note = h.capture_notify()
        vim.cmd("edit " .. vim.fn.fnameescape(BROKEN))
        local buf = vim.api.nvim_get_current_buf()
        runner.run_project()
        h.wait(function() return #vim.diagnostic.get(buf, { namespace = compiler.ns }) == 2 end, 5000)
        local got = {}
        for _, d in ipairs(vim.diagnostic.get(buf, { namespace = compiler.ns })) do
            got[#got + 1] = (d.lnum + 1) .. ":" .. (d.col + 1) .. " " .. d.message
        end
        table.sort(got)
        assert.are.same({
            "4:9 Variable 'unused' is never used",
            "5:12 Unresolved reference 'missing'.",
        }, got)
        h.wait(function() return note.msg ~= nil end)
        assert.are.equal("kotlin-lite: 1 compiler error, 1 warning", note.msg)
    end)
end)
