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

    local cases = {
        { "member through its receiver", "gd/dsl/UseDsl.kt", "// apply on pen", "stroke", "gd.dsl.Pen.stroke" },
        { "class declared here", "gd/dsl/Dsl.kt", "class Pen", "Pen", "gd.dsl.Pen" },
        { "top-level fun", "gd/dsl/UseDsl.kt", "canvas {", "canvas", "gd.dsl.canvas" },
        { "a local: the file", "gd/dsl/UseDsl.kt", "p.apply", "p", "gd.dsl.UseDsl" },
    }
    for _, c in ipairs(cases) do
        local name, file, needle, word, want = unpack(c)
        it("symbol under the cursor: " .. name, function()
            h.open(file)
            h.cursor_at(needle, word)
            assert.are.equal(want, actions.copy_fqname())
            assert.are.equal(want, vim.fn.getreg("+"))
        end)
    end
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

describe("rename_file with its top-level entity", function()
    -- a two-module project under the fixtures: lib declares rf.Widget, app
    -- uses it, rfother.Widget is another class of the same name
    local ROOT = h.fixtures .. "/renamefile"
    local OLD, NEW = ROOT .. "/lib/src/main/kotlin/rf/Widget.kt", ROOT .. "/lib/src/main/kotlin/rf/Gadget.kt"
    local USE = ROOT .. "/app/src/main/kotlin/rfapp/Use.kt"
    local OTHER = ROOT .. "/app/src/main/kotlin/rfother/Uses.kt"
    local function write(path, lines)
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        vim.fn.writefile(lines, path)
    end
    before_each(function()
        write(ROOT .. "/lib/build.gradle.kts", {})
        write(ROOT .. "/app/build.gradle.kts", {})
        write(OLD, { "package rf", "", "// a Widget", "class Widget {", '    val label = "Widget"', "}" })
        write(USE, { "package rfapp", "", "import rf.Widget", "", "fun make(): Widget = Widget()" })
        write(OTHER, { "package rfother", "", "class Widget", "", "fun other() = Widget()" })
        h.stub(vim.ui, "input", function(_, cb) cb("Gadget") end)
    end)
    after_each(function()
        h.reset()
        vim.fn.delete(ROOT, "rf")
    end)

    local function rename_file()
        h.open("renamefile/lib/src/main/kotlin/rf/Widget.kt")
        actions.rename_file()
    end

    it("the entity by what it resolves to, in every module that sees it", function()
        rename_file()
        assert.is_not_nil(h.rename_preview())
        h.preview_press("<CR>")
        h.wait(function() return vim.fn.readfile(USE)[3] == "import rf.Gadget" end)
        assert.are.same({ "package rfapp", "", "import rf.Gadget", "", "fun make(): Gadget = Gadget()" },
            vim.fn.readfile(USE))
        assert.are.same({ "package rf", "", "// a Widget", "class Gadget {", '    val label = "Widget"', "}" },
            vim.fn.readfile(NEW))
        assert.are.same({ "package rfother", "", "class Widget", "", "fun other() = Widget()" }, vim.fn.readfile(OTHER))
        assert.are.equal(0, vim.fn.filereadable(OLD))
    end)

    it("the preview cancelled: the file renamed, nothing else", function()
        rename_file()
        h.preview_press("q")
        assert.is_nil(h.rename_preview(true))
        assert.are.equal("class Widget {", vim.fn.readfile(NEW)[4])
        assert.are.equal("import rf.Widget", vim.fn.readfile(USE)[3])
    end)

    it("a buffer with unsaved changes: moved, the changes carried over, not written", function()
        h.open("renamefile/lib/src/main/kotlin/rf/Widget.kt")
        vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// mine" })
        h.cursor_at("class Widget", "Widget")
        actions.rename_file()
        assert.is_not_nil(h.rename_preview())
        h.preview_press("q")
        assert.are.equal(NEW, h.bufname())
        assert.is_true(vim.bo.modified)
        assert.are.equal("// mine", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
        assert.are.equal("class Widget", vim.api.nvim_get_current_line():match("^class Widget"))
        assert.are.equal("package rf", vim.fn.readfile(NEW)[1], "the file as it was on disk")
        assert.are.equal(0, vim.fn.filereadable(OLD))
        assert.are.equal(-1, vim.fn.bufnr("^" .. OLD .. "$"))
        vim.cmd("silent write") -- no E13: the buffer is the file's
        assert.are.equal("// mine", vim.fn.readfile(NEW)[1])
    end)

    it("a buffer without changes: moved as it is", function()
        rename_file()
        h.preview_press("q")
        assert.are.equal(NEW, h.bufname())
        assert.is_false(vim.bo.modified)
        assert.are.equal("class Widget {", vim.fn.readfile(NEW)[4])
    end)
end)

describe("rename_file of a Java file with its class", function()
    -- lib declares rfj.Widget in Java; Kotlin and Java code of app use it
    local ROOT = h.fixtures .. "/renamejava"
    local OLD, NEW = ROOT .. "/lib/src/main/java/rfj/Widget.java", ROOT .. "/lib/src/main/java/rfj/Gadget.java"
    local USE_KT = ROOT .. "/app/src/main/kotlin/rfjapp/Use.kt"
    local USE_JAVA = ROOT .. "/app/src/main/java/rfjapp/UseJ.java"
    local OTHER = ROOT .. "/app/src/main/kotlin/rfjother/Uses.kt"
    local function write(path, lines)
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        vim.fn.writefile(lines, path)
    end
    before_each(function()
        write(ROOT .. "/lib/build.gradle.kts", {})
        write(ROOT .. "/app/build.gradle.kts", {})
        write(OLD, {
            "package rfj;", "", "// a Widget", "public final class Widget {",
            '    private final String label = "Widget";', "", "    public Widget() {}", "",
            "    public Widget(String label) {}", "", "    public static Widget make() {",
            "        return new Widget();", "    }", "}",
        })
        write(USE_KT, { "package rfjapp", "", "import rfj.Widget", "", "fun make(): Widget = Widget()" })
        write(USE_JAVA, { "package rfjapp;", "", "import rfj.Widget;", "", "class UseJ {",
            '    Widget w = new Widget("x");', "}" })
        write(OTHER, { "package rfjother", "", "class Widget", "", "fun other() = Widget()" })
        h.stub(vim.ui, "input", function(_, cb) cb("Gadget") end)
    end)
    after_each(function()
        h.reset()
        vim.fn.delete(ROOT, "rf")
    end)

    it("the class, its constructors and its usages in Kotlin and Java", function()
        h.open("renamejava/lib/src/main/java/rfj/Widget.java")
        actions.rename_file()
        assert.is_not_nil(h.rename_preview())
        h.preview_press("<CR>")
        h.wait(function() return vim.fn.readfile(USE_JAVA)[3] == "import rfj.Gadget;" end)
        assert.are.same({
            "package rfj;", "", "// a Widget", "public final class Gadget {",
            '    private final String label = "Widget";', "", "    public Gadget() {}", "",
            "    public Gadget(String label) {}", "", "    public static Gadget make() {",
            "        return new Gadget();", "    }", "}",
        }, vim.fn.readfile(NEW))
        assert.are.same({ "package rfjapp", "", "import rfj.Gadget", "", "fun make(): Gadget = Gadget()" },
            vim.fn.readfile(USE_KT))
        assert.are.same({ "package rfjapp;", "", "import rfj.Gadget;", "", "class UseJ {",
            '    Gadget w = new Gadget("x");', "}" }, vim.fn.readfile(USE_JAVA))
        assert.are.same({ "package rfjother", "", "class Widget", "", "fun other() = Widget()" }, vim.fn.readfile(OTHER))
        assert.are.equal(0, vim.fn.filereadable(OLD))
    end)
end)

describe("rename_file: top-level entity detection, Java", function()
    local entity = actions._toplevel_entity
    it("class / enum / record / interface / annotation", function()
        assert.are.equal("class", entity({ "package p;", "public final class Foo<T> extends Bar {" }, "Foo"))
        assert.are.equal("enum", entity({ "public enum Foo {" }, "Foo"))
        assert.are.equal("record", entity({ "public record Foo(int x) {}" }, "Foo"))
        assert.are.equal("interface", entity({ "interface Foo {" }, "Foo"))
        assert.are.equal("@interface", entity({ "public @interface Foo {" }, "Foo"))
        assert.is_nil(entity({ "public class FooBar {" }, "Foo"))
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

    it("runs in the file's directory, so ktlint finds the project's .editorconfig", function()
        require("kotlin-lite.config").setup({ formatprg = "pwd", format_on_equal = false })
        h.open("calls/other/Ticker.kt")
        actions.format_buffer()
        assert.are.same({ h.fixtures .. "/calls/other" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    end)
end)
