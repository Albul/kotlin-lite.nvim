local h = require("helpers")
local actions = require("kotlin-lite.actions")

describe("alternate file", function()
    after_each(h.reset)

    it("main -> test", function()
        h.open("src/main/kotlin/com/example/Sample.kt")
        actions.alternate_file()
        assert.are.equal("src/test/kotlin/com/example/SampleTest.kt", h.relname())
    end)

    it("test -> main", function()
        h.open("src/test/kotlin/com/example/SampleTest.kt")
        actions.alternate_file()
        assert.are.equal("src/main/kotlin/com/example/Sample.kt", h.relname())
    end)
end)

describe("copy_fqname", function()
    after_each(h.reset)

    it("package + file name", function()
        h.open("Main.kt")
        assert.are.equal("fixtures.Main", actions.copy_fqname())
    end)
end)

describe("rename_file", function()
    after_each(h.reset)

    describe("top-level entity detection", function()
        local entity = actions._toplevel_entity

        it("data class", function()
            assert.are.equal("class", entity({ "package p", "", "data class Foo(val x: Int)" }, "Foo"))
        end)
        it("interface", function()
            assert.are.equal("interface", entity({ "interface Bar {" }, "Bar"))
        end)
        it("top-level fun", function()
            assert.are.equal("fun", entity({ "fun greet() {}" }, "greet"))
        end)
        it("ignores indented (nested)", function()
            assert.is_nil(entity({ "    class Inner" }, "Inner"))
        end)
        it("no prefix false-match", function()
            assert.is_nil(entity({ "class FooBar" }, "Foo"))
        end)
    end)

    it("moves the file end to end", function()
        local dir = vim.fn.fnamemodify(vim.fn.tempname(), ":h")
        local old_path, new_path = dir .. "/RenameMe.kt", dir .. "/Renamed.kt"
        finally(function()
            vim.fn.delete(old_path)
            vim.fn.delete(new_path)
        end)
        -- `class Other` deliberately mismatches the file name -> no entity confirm
        vim.fn.writefile({ "package t", "", "class Other" }, old_path)
        vim.cmd("edit! " .. vim.fn.fnameescape(old_path))
        vim.bo.filetype = "kotlin"

        h.stub(vim.ui, "input", function(_, cb) cb("Renamed") end)
        actions.rename_file()

        assert.matches("/Renamed%.kt$", h.bufname())
        assert.are.equal(1, vim.fn.filereadable(new_path))
        assert.are.equal(0, vim.fn.filereadable(old_path))
    end)
end)

describe("format_buffer", function()
    after_each(h.reset)

    it("replaces the buffer with the formatter's stdout", function()
        require("kotlin-lite.config").setup({ formatprg = "tr a-z A-Z", format_on_equal = false })
        vim.cmd("enew")
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "package p", "class widget" })
        actions.format_buffer()
        assert.are.same({ "PACKAGE P", "CLASS WIDGET" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    end)
end)
