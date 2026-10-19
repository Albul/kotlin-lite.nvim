local h = require("helpers")
local actions = require("kotlin-lite.actions")
local autoimport = require("kotlin-lite.autoimport")

describe("auto-import", function()
    local note, picked

    before_each(function()
        note, picked = nil, nil
        h.stub(vim, "notify", function(msg) note = msg end)
        h.stub(vim.ui, "select", function(list)
            picked = vim.tbl_map(function(c) return c.fq end, list)
        end)
    end)
    after_each(h.reset)

    local function import_lines()
        local out = {}
        for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, 10, false)) do
            if l:match("^import ") then out[l] = true end
        end
        return out
    end

    -- run auto-import on `word` in the first line containing `needle`;
    -- -> the added import line, or nil (then see `note` / `picked`)
    local function run(file, needle, word)
        h.open(file)
        local before = import_lines()
        h.cursor_at(needle, word)
        local tick = vim.b.changedtick
        actions.auto_import_under_cursor()
        h.wait(function() return note ~= nil or picked ~= nil or vim.b.changedtick ~= tick end)
        for l in pairs(import_lines()) do
            if not before[l] then return l end
        end
    end

    describe("imports by fully qualified path", function()
        local cases = {
            { "Circle(1.0)", "Circle", "fixtures.Circle" },
            { "aiTopFun(1)", "aiTopFun", "autoimport.lib.aiTopFun" },
            { "aiShout", "aiShout", "autoimport.lib.aiShout" },
            { "aiTopVal", "aiTopVal", "autoimport.lib.aiTopVal" },
            { "AI_TOP_CONST", "AI_TOP_CONST", "autoimport.lib.AI_TOP_CONST" },
            { "AI_MAX", "AI_MAX", "autoimport.lib.AiConsts.AI_MAX" },
            { "aiHelper", "aiHelper", "autoimport.lib.AiConsts.aiHelper" },
            { "AI_ONE", "AI_ONE", "autoimport.lib.AiOneLine.AI_ONE" },
            { "AiNested", "AiNested", "autoimport.lib.AiOuter.AiNested" },
            { "AI_COMP", "AI_COMP", "autoimport.lib.AiOuter.Companion.AI_COMP" },
            { "AI_RED", "AI_RED", "autoimport.lib.AiColor.AI_RED" },
            { "AI_LARGE", "AI_LARGE", "autoimport.lib.AiSize.AI_LARGE" },
            { "AI_LIMIT", "AI_LIMIT", "autoimport.lib.AiStatics.AI_LIMIT" },
            { "aiTwice", "aiTwice", "autoimport.lib.AiStatics.aiTwice" },
            { "AiInner", "AiInner", "autoimport.lib.AiStatics.AiInner" },
        }
        for _, c in ipairs(cases) do
            local needle, word, fq = unpack(c)
            it(word .. " -> " .. fq, function()
                assert.are.equal("import " .. fq, run("autoimport/Use.kt", needle, word))
            end)
        end
    end)

    describe("offers no import for", function()
        local cases = {
            { "ByteArray(16)", "ByteArray", "default-imported kotlin.ByteArray" },
            { "aiMember", "aiMember", "a class member after a dot" },
            { "aiHidden", "aiHidden", "a private top-level fun" },
            { "aiLocal", "aiLocal", "a local val" },
            { "aiCtorProp", "aiCtorProp", "a ctor property" },
            { "aiInstance", "aiInstance", "a java instance field" },
        }
        for _, c in ipairs(cases) do
            local needle, word, what = unpack(c)
            it(what, function()
                assert.is_nil(run("autoimport/Use.kt", needle, word))
                assert.is_nil(picked)
            end)
        end

        it("a member inherited from a supertype", function()
            assert.is_nil(run("autoimport/UseBase.kt", "// inherited member", "aiShared"))
            assert.is_nil(picked)
            assert.truthy(note:find("member of AiBase", 1, true), note)
        end)

        it("a class in the same package", function()
            assert.is_nil(run("Main.kt", "Circle(radius)", "Circle"))
            assert.truthy(note:find("same package", 1, true))
        end)
    end)

    it("the same name outside the class: imported", function()
        assert.are.equal("import autoimport.shared.aiShared", run("autoimport/UseBase.kt", "// not a member here", "aiShared"))
    end)

    it("same name in two packages -> picker", function()
        run("autoimport/Use.kt", "aiDup()", "aiDup")
        assert.are.same({ "autoimport.lib.aiDup", "autoimport.other.aiDup" }, picked)
    end)

    describe("placement", function()
        local buf
        before_each(function() buf = vim.api.nvim_create_buf(false, true) end)

        it("after the package line + a blank line", function()
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "package p", "", "fun x() = 1" })
            autoimport.insert(buf, "a.B")
            assert.are.same({ "package p", "", "import a.B", "", "fun x() = 1" },
                vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        end)

        it("no package -> top + a blank line", function()
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fun main() {", "}" })
            autoimport.insert(buf, "a.B")
            assert.are.same({ "import a.B", "", "fun main() {", "}" },
                vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        end)
    end)
end)

describe("autoimport.owners", function()
    local function names(lines, needle)
        for i, l in ipairs(lines) do
            if l:find(needle, 1, true) then
                local chain = autoimport.owners(lines, i)
                return chain and table.concat(vim.tbl_map(function(o) return o.name end, chain), " < ") or nil
            end
        end
    end

    it("a one-line header", function()
        assert.are.equal("A", names({ "class A {", "    val x = 1", "}" }, "val x"))
    end)
    it("a member of a fun body: local", function()
        assert.is_nil(names({ "class A {", "    fun f() {", "        val x = 1", "    }", "}" }, "val x"))
    end)
    it("the primary constructor on a line of its own (kotlin.time.Duration)", function()
        local lines = {
            "@JvmInline",
            "public value class Duration",
            "// a comment",
            '@Deprecated("x", level = DeprecationLevel.ERROR)',
            "internal constructor(private val rawValue: Long) :",
            "    Comparable<Duration> {",
            "",
            "    public companion object {",
            "        public val ZERO: Duration = Duration(0L)",
            "        public inline val Int.days: Duration get() = TODO()",
            "    }",
            "}",
        }
        assert.are.equal("Companion < Duration", names(lines, "val ZERO"))
        assert.are.equal("Companion < Duration", names(lines, "Int.days"))
    end)
    it("a multi-line constructor", function()
        local lines = {
            "public class Foo",
            "private constructor(",
            "    val a: Int = 0,",
            ") {",
            "    fun bar() = a",
            "}",
        }
        assert.are.equal("Foo", names(lines, "fun bar"))
    end)
    it("the brace on a line of its own after extends (java.nio.file.Path)", function()
        local lines = {
            "public interface Path",
            "    extends Comparable<Path>, Iterable<Path>, Watchable",
            "{",
            "    default File toFile() {",
            "        return null;",
            "    }",
            "}",
        }
        assert.are.equal("Path", names(lines, "File toFile"))
        assert.is_nil(names(lines, "return null"))
    end)
    it("a java method with its brace on a line of its own: still local", function()
        local lines = { "class A {", "    void f()", "    {", "        int x = 1;", "    }", "}" }
        assert.is_nil(names(lines, "int x"))
    end)
    it("a secondary constructor's body: local, even after a nested class without a body", function()
        local lines = {
            "class A {",
            "    class B",
            "    constructor(y: Int) : this() {",
            "        val z = y",
            "    }",
            "}",
        }
        assert.is_nil(names(lines, "val z"))
    end)
    it("a header closed by its brace above: no continuation", function()
        local lines = { "class A {", "}", "internal constructor(x: Int) {", "    val z = x", "}" }
        assert.is_nil(names(lines, "val z"))
    end)
end)
