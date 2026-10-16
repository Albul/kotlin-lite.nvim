local h = require("helpers")
local actions = require("kotlin-lite.actions")

describe("gd", function()
    after_each(h.reset)

    it("local val -> same buffer", function()
        h.open("Main.kt")
        h.cursor_at("Circle(radius)", "radius")
        actions.goto_definition() -- in-buffer path is synchronous
        assert.are.equal("Main.kt", h.relname())
        assert.are.equal(h.line_of("val radius"), h.cur_line())
    end)

    it("class -> another file", function()
        h.open("Main.kt")
        h.cursor_at("Circle(radius)", "Circle")
        actions.goto_definition() -- project path is async (rg + vim.schedule)
        assert.is_true(h.wait_jump())
        assert.are.equal("Geometry.kt", h.relname())
        assert.truthy(vim.api.nvim_get_current_line():find("class Circle", 1, true))
    end)

    it("is case-sensitive even with 'ignorecase' (Circle is not the `circle` val)", function()
        vim.o.ignorecase = true
        finally(function() vim.o.ignorecase = false end)
        h.open("Main.kt")
        h.cursor_at("Circle(radius)", "Circle")
        actions.goto_definition()
        assert.is_true(h.wait_jump())
        assert.truthy(vim.api.nvim_get_current_line():find("class Circle", 1, true))
    end)
end)

describe("gd picker", function()
    after_each(h.reset)

    describe("expect / actual", function()
        local cap, rows

        before_each(function()
            cap = h.capture_select()
            h.open("defs/shared/src/commonMain/kotlin/UseClock.kt")
            h.cursor_at("c: KmpClock", "KmpClock")
            actions.goto_definition()
            h.wait(function() return cap.list ~= nil end)
            rows = h.format_rows(cap)
        end)

        it("is titled with the word", function()
            assert.are.equal("Definition: KmpClock", cap.opts.prompt)
        end)

        it("lists expect first, then the actuals", function()
            assert.are.equal(3, #rows)
            assert.matches("^expect%s+class KmpClock%s+common%s+defs/shared · KmpClock%.kt:3$", rows[1])
            assert.matches("^actual%s+class KmpClock%s+apple%s+", rows[2])
            assert.matches("^actual%s+class KmpClock%s+jvm%s+.*KmpClock%.jvm%.kt:3$", rows[3])
        end)

        it("drops 'public' and aligns the origin column", function()
            assert.falsy(table.concat(rows, "\n"):find("public", 1, true))
            local cols = vim.tbl_map(function(l) return (l:find("defs/shared", 1, true)) end, rows)
            assert.is_not_nil(cols[1])
            assert.are.same({ cols[1], cols[1], cols[1] }, cols)
        end)

        it("rows carry file + pos for preview and highlight chunks", function()
            local r = cap.list[1]
            assert.matches("KmpClock%.kt$", r.file)
            assert.are.equal(3, r.pos[1])
            assert.are.equal("Keyword", r.chunks[1][2])
        end)
    end)

    describe("jar sources", function()
        local jars = require("kotlin-lite.jars")
        local defs = require("kotlin-lite.defs")
        local config = require("kotlin-lite.config") -- options is replaced by setup(): no local alias
        local saved_cache, tmp

        local function fake_jar(hash, name, rel, line)
            local dir = tmp .. "/" .. hash
            vim.fn.mkdir(vim.fn.fnamemodify(dir .. "/" .. rel, ":h"), "p")
            vim.fn.writefile({ "package kotlin", "", line }, dir .. "/" .. rel)
            vim.fn.writefile({ name }, dir .. "/.jarname")
            vim.fn.writefile({}, dir .. "/.extracted")
        end

        before_each(function()
            saved_cache, tmp = config.options.cache_dir, vim.fn.tempname()
            config.options.cache_dir = tmp
            fake_jar("a", "kotlin-stdlib-2.0.0-sources.jar", "commonMain/kotlin/JarThing.kt", "public expect interface JarThing {")
            fake_jar("b", "kotlin-stdlib-2.4.10-sources.jar", "commonMain/kotlin/JarThing.kt", "public expect interface JarThing {")
            fake_jar("c", "kotlin-stdlib-2.4.0-sources.jar", "commonMain/kotlin/JarThing.kt", "public expect interface JarThing {")
            fake_jar("d", "kotlin-stdlib-jdk8-1.9.0-sources.jar", "jvmMain/kotlin/JarThingJVM.kt", "public actual typealias JarThing = java.lang.Object")
            jars.scan_cache()
        end)

        after_each(function()
            config.options.cache_dir = saved_cache
            jars.scan_cache()
            vim.fn.delete(tmp, "rf")
        end)

        it("keeps only the newest version of each artifact", function()
            local cap = h.capture_select()
            vim.cmd.enew()
            vim.bo.filetype = "kotlin"
            vim.api.nvim_buf_set_lines(0, 0, -1, false, { "val x: JarThing = TODO()" })
            h.cursor_on(1, "JarThing")
            actions.goto_definition()
            h.wait(function() return cap.list ~= nil end)

            local rows = h.format_rows(cap)
            assert.are.equal(2, #rows)
            assert.truthy(rows[1]:find("kotlin-stdlib 2.4.10 · JarThing.kt:3", 1, true))
            assert.truthy(rows[2]:find("kotlin-stdlib-jdk8 1.9.0 · JarThingJVM.kt:3", 1, true))
            assert.falsy(table.concat(rows, "\n"):find("%[jar%]"))
        end)

        it("latest_only leaves project items alone", function()
            local mixed = defs.latest_only({
                { filename = h.fixtures .. "/Geometry.kt", lnum = 1, text = "class Circle" },
                { filename = tmp .. "/a/commonMain/kotlin/JarThing.kt", lnum = 3, text = "" },
                { filename = tmp .. "/b/commonMain/kotlin/JarThing.kt", lnum = 3, text = "" },
            })
            assert.are.equal(2, #mixed)
            assert.matches("Geometry", mixed[1].filename)
            assert.truthy(mixed[2].filename:find("/b/", 1, true))
        end)
    end)
end)

describe("gd on an import line", function()
    after_each(h.reset)

    describe("import_target", function()
        local function target(line, word)
            return actions._import_target(line, word)
        end

        it("last segment", function()
            assert.are.same({ name = "Inner", qualifier = "a.b.Foo" },
                target("import a.b.Foo.Inner", "Inner"))
        end)
        it("middle segment", function()
            assert.are.same({ name = "Foo", qualifier = "a.b" }, target("import a.b.Foo.Inner", "Foo"))
        end)
        it("package segment -> whole import", function()
            assert.are.same({ name = "Inner", qualifier = "a.b.Foo" }, target("import a.b.Foo.Inner", "b"))
        end)
        it("keyword -> whole import", function()
            assert.are.same({ name = "Inner", qualifier = "a.b.Foo" }, target("import a.b.Foo.Inner", "import"))
        end)
        it("package segment of a fun import", function()
            assert.are.same({ name = "foo", qualifier = "a.b" }, target("import a.b.foo", "b"))
        end)
        it("wildcard", function()
            assert.are.equal("a.b", target("import a.b.*", "b").wildcard)
        end)
        it("alias -> original name", function()
            local t = target("import a.b.foo as bar", "bar")
            assert.are.equal("foo", t.name)
            assert.are.equal("a.b", t.qualifier)
        end)
        it("not an import line", function()
            assert.is_nil(target("val x = a.b.Foo", "Foo"))
        end)
    end)

    describe("jumps without a picker", function()
        local picked

        before_each(function()
            picked = false
            h.stub(vim.ui, "select", function() picked = true end)
        end)

        local cases = {
            { "class -> its package", "import defs.other.Dup", "Dup", "defs/imports/other/Dup.kt", 3 },
            { "nested class via outer qualifier", "import defs.main.Outer.Inner", "Inner", "defs/imports/main/Dup.kt", 6 },
            { "outer segment of nested import", "import defs.main.Outer.Inner", "Outer", "defs/imports/main/Dup.kt", 5 },
            { "package segment -> imported class", "import defs.other.Dup", "other", "defs/imports/other/Dup.kt", 3 },
            { "package segment of nested import -> innermost class", "import defs.main.Outer.Inner", "main", "defs/imports/main/Dup.kt", 6 },
            { "alias -> aliased top-level fun", "import defs.main.dupFun", "aliasFun", "defs/imports/main/Dup.kt", 9 },
        }
        for _, c in ipairs(cases) do
            local name, needle, word, file, lnum = unpack(c)
            it(name, function()
                h.open("defs/imports/user/User.kt")
                h.cursor_at(needle, word)
                actions.goto_definition()
                assert.is_true(h.wait_jump())
                assert.is_false(picked)
                assert.are.equal(file, h.relname())
                assert.are.equal(lnum, h.cur_line())
            end)
        end

        it("unknown package -> stays put, no fallback to a same-named class", function()
            h.open("defs/imports/user/Missing.kt")
            h.cursor_at("import defs.missing.Dup", "Dup")
            actions.goto_definition()
            h.wait_jump(nil, 600)
            assert.are.equal("defs/imports/user/Missing.kt", h.relname())
            assert.is_false(picked)
        end)
    end)
end)

describe("gd ranked by the file header", function()
    local cap

    before_each(function() cap = h.capture_select() end)
    after_each(h.reset)

    local function gd_on(file, needle, word)
        h.open(file)
        local start = h.bufname()
        h.cursor_at(needle, word)
        actions.goto_definition()
        h.wait(function() return cap.list ~= nil or h.bufname() ~= start end)
    end

    local jumps = {
        { "explicit import wins over another package", "defs/imports/user/User.kt", "fun use", "Dup", "defs/imports/other/Dup.kt", 3 },
        { "explicit nested import", "defs/imports/user/User.kt", "fun use", "Inner", "defs/imports/main/Dup.kt", 6 },
        { "alias used in code -> aliased decl", "defs/imports/user/User.kt", "fun use", "aliasFun", "defs/imports/main/Dup.kt", 9 },
        { "same package, no import", "defs/imports/main/SamePkg.kt", "fun same", "Dup", "defs/imports/main/Dup.kt", 3 },
        { "star import", "defs/imports/user/Star.kt", "fun star", "Dup", "defs/imports/other/Dup.kt", 3 },
    }
    for _, c in ipairs(jumps) do
        local name, file, needle, word, target, lnum = unpack(c)
        it(name, function()
            gd_on(file, needle, word)
            assert.is_nil(cap.list)
            assert.are.equal(target, h.relname())
            assert.are.equal(lnum, h.cur_line())
        end)
    end

    it("nothing in the header -> picker with all, no markers", function()
        gd_on("defs/imports/user/Bare.kt", "fun bare", "Dup")
        local rows = h.format_rows(cap)
        assert.are.equal(2, #rows)
        assert.falsy(rows[1]:find("●", 1, true))
    end)

    it("tie on the best rank -> picker, matched rows marked and first", function()
        gd_on("defs/imports/user/Mixed.kt", "fun mixed", "Twin")
        local rows = h.format_rows(cap)
        assert.are.equal(3, #rows)
        assert.matches("^● expect%s+class Twin", rows[1])
        assert.matches("^● actual%s+class Twin", rows[2])
        assert.matches("^  %s*class Twin%s+defs/imports/other · Twin%.kt:3$", rows[3])
    end)
end)

describe("K", function()
    after_each(h.reset)

    it("hovers the declaration the header points at", function()
        local shown
        h.stub(vim.lsp.util, "open_floating_preview", function(lines) shown = lines end)
        h.open("defs/imports/user/User.kt")
        h.cursor_at("fun use", "Dup")
        actions.hover()
        h.wait(function() return shown ~= nil end)
        assert.is_not_nil(shown)
        assert.truthy(shown[#shown]:find("defs/imports/other/Dup.kt:3", 1, true))
    end)

    -- K on the `nth` `word` of the line with `needle` -> the float's lines
    local function hover(file, needle, word, nth, edit)
        local shown
        h.stub(vim.lsp.util, "open_floating_preview", function(lines) shown = lines end)
        h.open(file)
        if edit then edit() end
        h.cursor_at(needle, word, nth)
        actions.hover()
        h.wait(function() return shown ~= nil end)
        assert.is_not_nil(shown, "no float")
        return shown
    end

    local dsl = "gd/dsl/UseDsl.kt"
    -- { name, file, needle, word, nth, first line of the float, footer location }
    local cases = {
        { "member through the receiver's type", dsl, "// apply on pen", "stroke", 1,
            "fun stroke(width: Int, dash: Boolean = false) {}", "gd/dsl/Dsl.kt:8" },
        { "member through a DSL lambda receiver", dsl, "// dsl canvas", "stroke", 1,
            "fun stroke(width: Int) {}", "gd/dsl/Dsl.kt:4" },
        { "overload picked by the arguments", dsl, "// trailing lambda", "blend", 1,
            "fun blend(a: Int, block: () -> Unit) {}", "gd/dsl/Dsl.kt:26" },
        { "local, from this buffer", dsl, "lazyPen.stroke", "lazyPen", 1,
            "val lazyPen by lazy { Pen() }", "gd/dsl/UseDsl.kt:19" },
        { "named argument -> the parameter", dsl, "pen(tint", "tint", 1,
            "tint: String = \"black\",", "gd/dsl/Dsl.kt:14" },
        { "param, not a same-named local of another fun", "gd/scope/Scoped.kt", "println(local * 2)", "local", 1,
            "fun third(local: Int) {", "gd/scope/Scoped.kt:16" },
    }
    for _, c in ipairs(cases) do
        local name, file, needle, word, nth, first, where = unpack(c)
        it(name, function()
            local shown = hover(file, needle, word, nth)
            assert.are.equal(first, vim.trim(shown[1]))
            assert.truthy(shown[#shown]:find(where, 1, true), shown[#shown])
        end)
    end

    it("in-buffer declarations come from the buffer, unsaved edits included", function()
        local shown = hover(dsl, "p.apply", "p", 1, function()
            local l = h.line_of("val p = Pen()")
            vim.api.nvim_buf_set_lines(0, l - 1, l - 1, false, { "    /** the pen */" })
        end)
        assert.are.equal("/** the pen */", vim.trim(shown[1]))
        assert.are.equal("val p = Pen()", vim.trim(shown[2]))
        assert.truthy(shown[#shown]:find("gd/dsl/UseDsl.kt:13", 1, true), shown[#shown])
    end)

    it("nothing found -> a warning, no float", function()
        local shown
        h.stub(vim.lsp.util, "open_floating_preview", function(lines) shown = lines end)
        local note = h.capture_notify()
        h.open(dsl)
        h.cursor_at("fun useDsl", "useDsl")
        vim.api.nvim_buf_set_lines(0, -1, -1, false, { "val q = nowhereToBeFound()" })
        h.cursor_at("nowhereToBeFound", "nowhereToBeFound")
        actions.hover()
        h.wait(function() return note.msg ~= nil end)
        assert.is_nil(shown)
        assert.truthy((note.msg or ""):find("nowhereToBeFound", 1, true))
    end)
end)
