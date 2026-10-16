-- gd beyond name lookup: scope, receivers, named args, Java, noise.

local h = require("helpers")
local actions = require("kotlin-lite.actions")

-- gd on the `nth` `word` of the line containing `needle` in `file`; waits for
-- a jump (any cursor move) or a picker. -> the captured picker
local function gd(file, needle, word, nth)
    local cap = h.capture_select()
    h.open(file)
    h.cursor_at(needle, word, nth)
    local buf, pos = h.bufname(), vim.api.nvim_win_get_cursor(0)
    actions.goto_definition()
    h.wait(function()
        return cap.list ~= nil or h.bufname() ~= buf
            or not vim.deep_equal(vim.api.nvim_win_get_cursor(0), pos)
    end)
    return cap
end

-- the cursor sits on `word` of the line containing `needle` in `file`, no picker
local function assert_at(cap, file, needle, word)
    assert.is_nil(cap.list and h.format_rows(cap), "picker opened instead of a jump")
    assert.are.equal(file, h.relname())
    local lnum = h.line_of(needle)
    local col = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]:find(word, 1, true) - 1
    assert.are.same({ lnum, col }, vim.api.nvim_win_get_cursor(0))
end

-- { name, from file, needle, word, nth, to file, needle, word }
local function run_cases(cases)
    for _, c in ipairs(cases) do
        local name, file, needle, word, nth, to, to_needle, to_word = unpack(c)
        it(name, function()
            assert_at(gd(file, needle, word, nth), to, to_needle, to_word)
        end)
    end
end

local SCOPE = "gd/scope/Scoped.kt"

describe("gd lexical scope in the buffer", function()
    after_each(h.reset)

    run_cases({
        { "ctor property from a member fun", SCOPE, "println(title)", "title", 1, SCOPE, "class Scoped(val title", "title" },
        { "member val", SCOPE, "return count", "count", 1, SCOPE, "val count = 1", "count" },
        { "own param, not a same-named local of another fun", SCOPE, "println(local * 2)", "local", 1, SCOPE, "fun third(local", "local" },
        { "innermost shadowing local", SCOPE, "// inner", "count", 1, SCOPE, "val count = 3", "count" },
        { "local of a closed block is out of scope", SCOPE, "// outer", "count", 1, SCOPE, "val count = 2", "count" },
        { "local declared further down is not visible yet", SCOPE, "// before local", "count", 1, SCOPE, "val count = 1", "count" },
        { "local after its declaration", SCOPE, "// after local", "count", 1, SCOPE, "val count = 4", "count" },
        { "decls in block comments / strings don't count", SCOPE, "// masked", "count", 1, SCOPE, "val count = 1", "count" },
        { "lambda param", SCOPE, "println(item)", "item", 1, SCOPE, "forEach { item", "item" },
        { "for-loop variable", SCOPE, "println(idx)", "idx", 2, SCOPE, "for (idx", "idx" },
        { "string template expression", SCOPE, "// template", "count", 2, SCOPE, "val count = 1", "count" },
        { "member declared below its use", SCOPE, "fun later() = after", "after", 1, SCOPE, "val after = 5", "after" },
        { "KDoc reference to a ctor property", "Geometry.kt", "defined by its [radius]", "radius", 1, "Geometry.kt", "class Circle(val radius", "radius" },
    })
end)

describe("gd on a member's own declaration", function()
    after_each(h.reset)

    run_cases({
        { "override -> the overridden member", "gd/recv/Shapes.kt", "override fun summary()", "summary", 1, "gd/recv/Shapes.kt", "open fun summary()", "summary" },
        { "actual -> its expect", "defs/shared/src/jvmMain/kotlin/KmpClock.jvm.kt", "actual class KmpClock", "KmpClock", 1, "defs/shared/src/commonMain/kotlin/KmpClock.kt", "expect class KmpClock", "KmpClock" },
    })

    local stays = {
        { "plain member fun", "gd/recv/Shapes.kt", "fun extent() = span * span", "extent" },
        { "ctor property", "gd/recv/Shapes.kt", "class Orb(val span", "span" },
        { "param of a fun with a body", "gd/dsl/Dsl.kt", "fun canvas(block", "block" },
        { "param of a fun without a body, named like a property", "gd/dsl/Dsl.kt", "fun paint(layer", "layer" },
    }
    for _, c in ipairs(stays) do
        local name, file, needle, word = unpack(c)
        it(name .. ": stays", function()
            local cap = gd(file, needle, word)
            assert.is_nil(cap.list)
            assert.are.equal(file, h.relname())
            assert.are.equal(h.line_of(needle), h.cur_line())
        end)
    end
end)

describe("gd on a local's own declaration", function()
    after_each(h.reset)

    local cases = {
        { "local val", "val local = 1", "local" },
        { "lambda param", "forEach { item ->", "item" },
        { "fun param", "fun third(local: Int)", "local" },
    }
    for _, c in ipairs(cases) do
        local name, needle, word = unpack(c)
        it(name .. ": stays, searches nothing", function()
            local searched = false
            local engine = require("kotlin-lite.search").engine
            h.stub(require("kotlin-lite.search"), "engine", function(...)
                local E = engine(...)
                local start = E.start
                E.start = function(...) searched = true return start(...) end
                return E
            end)
            local cap = gd(SCOPE, needle, word)
            assert.is_nil(cap.list)
            assert.is_false(searched)
            assert.are.equal(SCOPE, h.relname())
            assert.are.equal(h.line_of(needle), h.cur_line())
        end)
    end
end)

local USE, SHAPES = "gd/recv/use/Use.kt", "gd/recv/Shapes.kt"

describe("gd through a receiver", function()
    after_each(h.reset)

    run_cases({
        { "param type", USE, "// param type", "extent", 1, SHAPES, "fun extent() = span * span", "extent" },
        { "type of a ctor call initializer", USE, "// ctor type", "extent", 1, SHAPES, "fun extent() = 3 * span", "extent" },
        { "declared type -> ctor property", USE, "// declared type", "span", 1, SHAPES, "class Orb(val span", "span" },
        { "member inherited from the supertype", USE, "// inherited", "ident", 1, SHAPES, "val ident = 0", "ident" },
        { "companion const", USE, "// companion val", "CAP", 1, SHAPES, "const val CAP", "CAP" },
        { "companion fun", USE, "// companion fun", "make", 1, SHAPES, "fun make()", "make" },
        { "entry of a one-line enum", USE, "// one-line enum", "TEAL", 1, SHAPES, "enum class Hue", "TEAL" },
        { "enum entry on its own line", USE, "// enum entry line", "SLOW", 1, SHAPES, "    SLOW;", "SLOW" },
        { "extension picked by receiver type (Orb)", USE, "// orb extension", "bulk", 1, SHAPES, "fun Orb.bulk", "bulk" },
        { "extension picked by receiver type (Crate)", USE, "// crate extension", "bulk", 1, SHAPES, "fun Crate.bulk", "bulk" },
        { "receiver is a ctor call", USE, "// ctor call receiver", "extent", 1, SHAPES, "fun extent() = span * span", "extent" },
        { "safe call", USE, "// safe call", "span", 1, SHAPES, "class Orb(val span", "span" },
        { "callable reference", USE, "Orb::extent", "extent", 1, SHAPES, "fun extent() = 3 * span", "extent" },
        { "fully qualified receiver", USE, "// qualified", "CRIMSON", 1, SHAPES, "enum class Hue", "CRIMSON" },
        { "this. -> member, not the shadowing local", SHAPES, "return span * this.span", "span", 2, SHAPES, "class Crate(val span", "span" },
        { "plain name next to this. -> the local", SHAPES, "return span * this.span", "span", 1, SHAPES, "val span = 2", "span" },
        { "super. -> supertype member", SHAPES, "super.summary()", "summary", 2, SHAPES, "open fun summary()", "summary" },
    })
end)

describe("gd on a named argument", function()
    after_each(h.reset)

    run_cases({
        { "-> parameter of the called fun", USE, "Ledger.enroll(label = \"x\"", "span", 1, SHAPES, "fun enroll(label: String, span", "span" },
        { "multi-line call", USE, "label = \"y\",", "label", 1, SHAPES, "fun enroll(label", "label" },
        { "-> ctor property of the called class", USE, "// ctor named arg", "span", 1, SHAPES, "class Orb(val span", "span" },
        { "an assignment is not a named argument", USE, "total = 5", "total", 1, USE, "var total = 0", "total" },
    })
end)

local LEGACY = "gd/java/Legacy.java"

describe("gd into Java", function()
    after_each(h.reset)

    run_cases({
        { "static method", "gd/java/UseJava.kt", "Legacy.of(", "of", 1, LEGACY, "public static Legacy of(", "of(" },
        { "a call prefers the method over a same-named field", "gd/java/UseJava.kt", "legacy.label()", "label", 1, LEGACY, "public String label()", "label" },
        { "static field", "gd/java/UseJava.kt", "Legacy.LIMIT", "LIMIT", 1, LEGACY, "public static final int LIMIT", "LIMIT" },
        { "entry of a nested enum", "gd/java/UseJava.kt", "Legacy.Kind.LARGE", "LARGE", 1, LEGACY, "public enum Kind", "LARGE" },
    })
end)

describe("gd skips what other files can't expose", function()
    after_each(h.reset)

    run_cases({
        { "local class and comment mention of a class", "gd/locals/UseLocals.kt", "println(Token(", "Token", 1, "gd/locals/Token.kt", "class Token(val raw", "Token" },
        { "local val of another file", "gd/locals/UseLocals.kt", "println(tokenLimit)", "tokenLimit", 1, "gd/locals/Token.kt", "val tokenLimit = 3", "tokenLimit" },
        { "imported from a file whose directory doesn't match its package", "gd/locals/UseStray.kt", "s: Stray", "Stray", 1, "gd/misplaced/Elsewhere.kt", "class Stray", "Stray" },
        { "import line of such a file", "gd/locals/UseStray.kt", "import gd.away.Stray", "Stray", 1, "gd/misplaced/Elsewhere.kt", "class Stray", "Stray" },
        { "unqualified call -> top-level fun, not a member of another class", "Main.kt", "val rectArea = area(", "area", 1, "Geometry.kt", "fun area(width", "area" },
        { "member call -> the member", "Main.kt", "println(circle.area())", "area", 1, "Geometry.kt", "fun area(): Double", "area" },
        { "member in a string template, not a same-named local", "Main.kt", "circle with radius", "radius", 2, "Geometry.kt", "class Circle(val radius", "radius" },
    })
end)

local USE_DSL, DSL = "gd/dsl/UseDsl.kt", "gd/dsl/Dsl.kt"

describe("gd inside a lambda with a receiver", function()
    after_each(h.reset)

    run_cases({
        { "DSL builder: receiver from the callee's `T.() -> Unit` param", USE_DSL, "// dsl canvas", "stroke", 1, DSL, "fun stroke(width: Int) {}", "stroke" },
        { "nested in a plain lambda", USE_DSL, "// dsl pen through", "stroke", 1, DSL, "fun stroke(width: Int, dash", "stroke" },
        { "x.apply { }", USE_DSL, "// apply on pen", "stroke", 1, DSL, "fun stroke(width: Int, dash", "stroke" },
        { "with(x) { }", USE_DSL, "// with canvas", "stroke", 1, DSL, "fun stroke(width: Int) {}", "stroke" },
        { "type of a `by lazy { Foo() }` val", USE_DSL, "// lazy type", "stroke", 1, DSL, "fun stroke(width: Int, dash", "stroke" },
    })
end)

describe("gd picks an overload by the number of arguments", function()
    after_each(h.reset)

    run_cases({
        { "one argument", USE_DSL, "// one arg", "blend", 1, DSL, "fun blend(a: Int) {}", "blend" },
        { "default parameter left out", USE_DSL, "// two args", "blend", 1, DSL, "fun blend(a: Int, b: Int", "blend" },
        { "trailing lambda counts", USE_DSL, "// trailing lambda", "blend", 1, DSL, "fun blend(a: Int, block", "blend" },
    })
end)

describe("gd on a named argument of an overloaded / multi-line callee", function()
    after_each(h.reset)

    run_cases({
        { "overload picked by the named args in the call", USE_DSL, "// overload by named args", "tint", 1, DSL, "fun draw(y: Int, tint", "tint" },
        { "parameter on its own line", USE_DSL, "pen(tint = ", "tint", 1, DSL, "    tint: String", "tint" },
    })
end)

describe("gd into jar sources: expect / actual by the file's source set", function()
    local jars = require("kotlin-lite.jars")
    local config = require("kotlin-lite.config") -- options is replaced by setup(): no local alias
    local saved_cache, tmp

    before_each(function()
        saved_cache, tmp = config.options.cache_dir, vim.fn.tempname()
        config.options.cache_dir = tmp
        local dir = tmp .. "/std"
        vim.fn.mkdir(dir .. "/commonMain/kotlin", "p")
        vim.fn.mkdir(dir .. "/jvmMain/kotlin", "p")
        vim.fn.writefile({ "package kotlin", "", "public expect class JarText" }, dir .. "/commonMain/kotlin/JarText.kt")
        vim.fn.writefile({ "package kotlin", "", "public actual class JarText" }, dir .. "/jvmMain/kotlin/JarTextJvm.kt")
        vim.fn.writefile({ "kotlin-stdlib-9.9.9-sources.jar" }, dir .. "/.jarname")
        vim.fn.writefile({}, dir .. "/.extracted")
        jars.scan_cache()
    end)

    after_each(function()
        h.reset()
        config.options.cache_dir = saved_cache
        jars.scan_cache()
        vim.fn.delete(tmp, "rf")
    end)

    it("the same common source shipped in several artifacts counts once", function()
        local dir = tmp .. "/std-desktop"
        vim.fn.mkdir(dir .. "/commonMain/kotlin", "p")
        vim.fn.writefile({ "package kotlin", "", "public class JarShared" }, dir .. "/commonMain/kotlin/JarShared.kt")
        vim.fn.writefile({ "kotlin-stdlib-desktop-9.9.9-sources.jar" }, dir .. "/.jarname")
        vim.fn.writefile({}, dir .. "/.extracted")
        vim.fn.mkdir(tmp .. "/std/commonMain/kotlin", "p")
        vim.fn.writefile({ "package kotlin", "", "public class JarShared" }, tmp .. "/std/commonMain/kotlin/JarShared.kt")
        jars.scan_cache()

        local cap = h.capture_select()
        vim.cmd.enew()
        vim.bo.filetype = "kotlin"
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "val x: JarShared = TODO()" })
        h.cursor_on(1, "JarShared")
        actions.goto_definition()
        h.wait(function() return cap.list ~= nil or h.bufname() ~= "" end)
        assert.is_nil(cap.list and h.format_rows(cap), "picker opened instead of a jump")
        assert.truthy(h.bufname():find("/std/commonMain/kotlin/JarShared.kt", 1, true))
    end)

    local cases = {
        { "commonMain -> expect", "gd/kmp/src/commonMain/kotlin/UseStd.kt", "JarText.kt" },
        { "jvmMain -> the jvm actual", "gd/kmp/src/jvmMain/kotlin/UseStdJvm.kt", "JarTextJvm.kt" },
        { "plain JVM project -> the jvm actual", "gd/plain/src/main/kotlin/UseStdPlain.kt", "JarTextJvm.kt" },
    }
    for _, c in ipairs(cases) do
        local name, file, target = unpack(c)
        it(name, function()
            local cap = gd(file, "text: JarText", "JarText")
            assert.is_nil(cap.list and h.format_rows(cap), "picker opened instead of a jump")
            assert.are.equal(target, vim.fs.basename(h.bufname()))
        end)
    end
end)

describe("'tagfunc' shares gd's resolution", function()
    after_each(h.reset)

    local function lnum_of(t) return tonumber(t.cmd:match("%%(%d+)l")) end

    it("receiver-typed member first", function()
        h.open(USE)
        h.cursor_at("// ctor type", "extent")
        local tags = actions.tagfunc("extent", "c")
        assert.matches("Shapes%.kt$", tags[1].filename)
        local lines = vim.fn.readfile(tags[1].filename)
        assert.truthy(lines[lnum_of(tags[1])]:find("fun extent() = 3 * span", 1, true))
    end)

    it("scope-aware local", function()
        h.open(SCOPE)
        h.cursor_at("// outer", "count")
        local tags = actions.tagfunc("count", "c")
        assert.are.equal(1, #tags)
        assert.are.equal(h.line_of("val count = 2"), lnum_of(tags[1]))
    end)
end)
