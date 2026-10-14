local h = require("helpers")
local actions = require("kotlin-lite.actions")
local impl = require("kotlin-lite.impl")

describe("impl.parse_header", function()
    local function supers(text)
        local hd = impl.parse_header(text)
        return hd and table.concat(hd.supers, ",") or nil
    end

    local cases = {
        { "plain", "class A : B, C {", "B,C" },
        { "ctor + super call + generics", "class A<T : X>(val a: Map<K, V>) : B<T>(a), C {", "B,C" },
        { "function types in ctor", "class A(val f: (Int) -> Unit) : B {", "B" },
        { "delegation", "class A(b: B) : B by b, C {", "B,C" },
        { "annotated private constructor", "class A @Inject private constructor(x: Int) : B()", "B" },
        { "qualified super", "class A : x.y.B {", "x.y.B" },
        { "where clause", "class A<T> : B<T> where T : C {", "B" },
        { "no supertypes", "data class A(val x: Int)", "" },
    }
    for _, c in ipairs(cases) do
        it("supertypes: " .. c[1], function()
            assert.are.equal(c[3], supers(c[2]))
        end)
    end

    it("kind + modifiers", function()
        local hd = impl.parse_header("sealed interface S : B")
        assert.are.equal("interface", hd.kind)
        assert.are.equal("S", hd.name)
        assert.is_true(hd.mods.sealed)
    end)

    it("anonymous object", function()
        local hd = impl.parse_header("val x = object : Runnable {")
        assert.are.equal("object", hd.kind)
        assert.is_nil(hd.name)
        assert.are.equal("Runnable", hd.supers[1])
    end)

    it("fun is not a header, fun interface is", function()
        assert.is_nil(impl.parse_header("fun interfaceOf(): Int"))
        assert.are.equal("F", impl.parse_header("fun interface F : G {").name)
    end)
end)

describe("impl.declares", function()
    local declares = impl._declares

    it("fun name, not its return type", function()
        assert.is_nil(declares("fun foo(): Flow<Int>", "Flow"))
        assert.are.equal("member", declares("fun foo(): Flow<Int>", "foo"))
    end)
    it("extension fun", function()
        assert.are.equal("member", declares("fun <T> List<T>.second(): T", "second"))
    end)
    it("val name, not its type", function()
        assert.is_nil(declares("val a: Foo = Foo()", "Foo"))
        assert.are.equal("member", declares("val a: Foo = Foo()", "a"))
    end)
    it("ctor property", function()
        assert.are.equal("member", declares("    override val name: String,", "name"))
    end)
    it("type header, not its supertype", function()
        assert.are.equal("type", declares("abstract class Polygon : Shape {", "Polygon"))
        assert.is_nil(declares("abstract class Polygon : Shape {", "Shape"))
    end)
end)

describe("gri", function()
    local cap

    before_each(function() cap = h.capture_select() end)
    after_each(h.reset)

    -- run gri on `word` in the line containing `needle` in `file`
    -- -> sorted "dir/File.kt:line" of the results (or of the jump target when
    --    there is a single one), whether a picker opened
    local function gri(file, needle, word)
        h.open(file)
        h.cursor_at(needle, word)
        local function pos() return h.bufname() .. ":" .. h.cur_line() end
        local start = pos()
        actions.goto_implementation()
        h.wait(function() return cap.list ~= nil or pos() ~= start end, 5000)
        local out = {}
        if cap.list then
            for _, row in ipairs(cap.list) do
                out[#out + 1] = row.data.filename:match("([^/]+/[^/]+)$") .. ":" .. row.data.lnum
            end
        elseif pos() ~= start then
            out[1] = h.bufname():match("([^/]+/[^/]+)$") .. ":" .. h.cur_line()
        end
        table.sort(out)
        return table.concat(out, " "), cap.list ~= nil
    end

    local shape = "impl/shapes/Shape.kt"
    local clock = "defs/shared/src/commonMain/kotlin/"

    local cases = {
        { "interface -> direct + transitive subtypes, anonymous object, other package",
            shape, "interface Shape", "Shape",
            "shapes/More.kt:10 shapes/More.kt:19 shapes/More.kt:4 shapes/Shape.kt:13 shapes/Shape.kt:18 shapes/Shape.kt:26 shapes/Shape.kt:8 user/Tri.kt:5" },
        { "interface fun -> overrides in subtypes only (not impl.other.Fake)",
            shape, "fun surface(): Double", "surface",
            "shapes/More.kt:14 shapes/More.kt:21 shapes/More.kt:6 shapes/Shape.kt:15 shapes/Shape.kt:22 shapes/Shape.kt:27 user/Tri.kt:7" },
        { "interface val -> overrides incl. ctor property",
            shape, "val name: String", "name",
            "shapes/More.kt:15 shapes/More.kt:22 shapes/More.kt:7 shapes/Shape.kt:10 shapes/Shape.kt:20 shapes/Shape.kt:28" },
        { "abstract val -> overrides across packages",
            shape, "abstract val sides", "sides", "shapes/Shape.kt:14 user/Tri.kt:6" },
        { "from a usage, resolved via import",
            "impl/user/Tri.kt", "class Triangle : Polygon", "Polygon", "shapes/Shape.kt:13 user/Tri.kt:5" },
        { "expect class -> actual classes",
            clock .. "KmpClock.kt", "expect class KmpClock", "KmpClock", "kotlin/KmpClock.apple.kt:3 kotlin/KmpClock.jvm.kt:3" },
        { "member of an expect class -> actual members",
            clock .. "KmpClock.kt", "fun now", "now", "kotlin/KmpClock.apple.kt:4 kotlin/KmpClock.jvm.kt:4" },
        { "expect class from a usage",
            clock .. "UseClock.kt", "fun useClock", "KmpClock", "kotlin/KmpClock.apple.kt:3 kotlin/KmpClock.jvm.kt:3" },
        { "final class -> nothing, stays put", shape, "class Square", "Square", "" },
    }
    for _, c in ipairs(cases) do
        local name, file, needle, word, want = unpack(c)
        it(name, function()
            assert.are.equal(want, (gri(file, needle, word)))
        end)
    end

    it("single implementation -> direct jump on the tag stack, no picker", function()
        local got, picked = gri("impl/other/Other.kt", "interface Shape", "Shape")
        assert.are.equal("other/Other.kt:8", got)
        assert.is_false(picked)
        assert.are.equal(1, vim.fn.gettagstack().length)
    end)
end)
