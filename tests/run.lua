-- Headless assertion runner for kotlin-lite.
--
--     nvim --headless -u tests/minimal_init.lua -l tests/run.lua
--
-- Drives the real actions against tests/fixtures/*.kt and checks that
-- gd (goto definition) and gr (find usages) behave as expected. Exits non-zero
-- if any check fails, so it can gate CI.

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local fixtures = tests_dir .. "/fixtures"
vim.cmd.cd(fixtures) -- project root for rg = the fixtures dir

local actions = require("kotlin-lite.actions")

-------------------------------------------------------------------
-- tiny test harness
-------------------------------------------------------------------
local failures = 0

local function check(name, ok, detail)
    if ok then
        io.write(("  ok    %s\n"):format(name))
    else
        failures = failures + 1
        io.write(("  FAIL  %s%s\n"):format(name, detail and ("   ->   " .. detail) or ""))
    end
end

local function open(file)
    vim.cmd("edit! " .. vim.fn.fnameescape(fixtures .. "/" .. file))
    vim.bo.filetype = "kotlin"
end

--- 1-based line number of the first line containing literal `needle`.
local function line_of(needle)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        if l:find(needle, 1, true) then return i end
    end
end

--- Put the cursor on the first occurrence of `word` on line `lnum`.
local function cursor_on(lnum, word)
    local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
    local col = line:find(word, 1, true)
    vim.api.nvim_win_set_cursor(0, { lnum, col - 1 })
end

local function bufname()
    return vim.api.nvim_buf_get_name(0)
end

local function cur_line()
    return vim.api.nvim_win_get_cursor(0)[1]
end

-------------------------------------------------------------------
-- Test 1: gd -> declaration inside the same buffer (a local `val`)
-------------------------------------------------------------------
do
    open("Main.kt")
    local decl = line_of("val radius")
    local usage = line_of("Circle(radius)")
    cursor_on(usage, "radius")

    actions.goto_definition() -- in-buffer path is synchronous

    check("gd: local val -> same buffer", bufname():match("Main%.kt$") ~= nil and cur_line() == decl,
        ("expected line %s, got %s"):format(decl, cur_line()))
end

-------------------------------------------------------------------
-- Test 2: gd -> declaration in another file (class Circle)
-------------------------------------------------------------------
do
    open("Main.kt")
    local usage = line_of("Circle(radius)")
    cursor_on(usage, "Circle")

    actions.goto_definition() -- project path is async (rg + vim.schedule)
    local jumped = vim.wait(4000, function()
        return bufname():match("Geometry%.kt$") ~= nil
    end, 40)

    local on_class = jumped and (vim.api.nvim_get_current_line():find("class Circle", 1, true) ~= nil)
    check("gd: class -> Geometry.kt", on_class, "did not land on `class Circle`")
end

-------------------------------------------------------------------
-- Test 3: gr -> find usages populates the quickfix list
-------------------------------------------------------------------
do
    open("Main.kt")
    local usage = line_of("area(3.0")
    cursor_on(usage, "area")

    vim.fn.setqflist({}, "r") -- clear
    actions.find_usages()
    vim.wait(4000, function() return #vim.fn.getqflist() > 0 end, 40)

    local qf = vim.fn.getqflist()
    local files = {}
    for _, it in ipairs(qf) do
        files[vim.api.nvim_buf_get_name(it.bufnr):match("([^/]+)$")] = true
    end
    check("gr: usages of `area` == 4", #qf == 4, "got " .. #qf)
    check("gr: usages span Geometry.kt + Main.kt", files["Geometry.kt"] and files["Main.kt"] or false)
end

-------------------------------------------------------------------
-- Test 4: keymaps attach on a kotlin buffer
-------------------------------------------------------------------
do
    open("Main.kt")
    check("keymaps: attached to kotlin buffer", vim.b.kotlin_lite_attached == true)
    check("keymaps: gd is mapped (buffer-local)", vim.fn.maparg("gd", "n") ~= "")
end

-------------------------------------------------------------------
-- Test 5: alternate file toggle (main <-> test)
-------------------------------------------------------------------
do
    open("src/main/kotlin/com/example/Sample.kt")
    actions.alternate_file()
    check("alternate: main -> test", bufname():match("src/test/kotlin/com/example/SampleTest%.kt$") ~= nil,
        bufname())

    open("src/test/kotlin/com/example/SampleTest.kt")
    actions.alternate_file()
    check("alternate: test -> main", bufname():match("src/main/kotlin/com/example/Sample%.kt$") ~= nil,
        bufname())
end

-------------------------------------------------------------------
-- Test 6: copy fully-qualified name
-------------------------------------------------------------------
do
    open("Main.kt")
    check("copy_fqname: package + file name", actions.copy_fqname() == "fixtures.Main")
end

-------------------------------------------------------------------
-- Test 7: auto-import inserts an import for a class defined elsewhere
-------------------------------------------------------------------
do
    open("Main.kt")
    local usage = line_of("Circle(radius)")
    cursor_on(usage, "Circle")

    actions.auto_import_under_cursor()
    local added = vim.wait(4000, function()
        return line_of("import fixtures.Circle") ~= nil
    end, 40)
    check("auto_import: adds `import fixtures.Circle`", added)
end

-------------------------------------------------------------------
-- Test 8: snacks integration degrades gracefully without snacks.nvim
-- (snacks is not on the test runtimepath)
-------------------------------------------------------------------
do
    local snacks = require("kotlin-lite.snacks")
    local config = require("kotlin-lite.config")

    -- capture vim.notify for the duration of these checks
    local orig_notify = vim.notify
    local last = {}
    vim.notify = function(msg, level) last = { msg = msg, level = level } end

    -- flag on (default), snacks missing -> polite warning, no crash
    config.setup({ snacks_integration = true })
    last = {}
    local ok1 = pcall(snacks.reveal)
    check("snacks: reveal() warns when snacks is missing",
        ok1 and last.level == vim.log.levels.WARN
        and last.msg == "kotlin-lite: 'snacks.nvim' is required for this feature, but it is not installed.",
        tostring(last.msg))

    -- flag off -> silent no-op (no notify, no crash)
    config.setup({ snacks_integration = false })
    last = {}
    local ok2 = pcall(snacks.reveal)
    check("snacks: reveal() is a silent no-op when disabled", ok2 and last.msg == nil)
    check("snacks: explorer_opts() is empty when disabled", vim.tbl_isempty(snacks.explorer_opts()))

    -- flag on -> opts are produced without requiring snacks
    config.setup({ snacks_integration = true })
    local opts = snacks.explorer_opts()
    check("snacks: explorer_opts() exposes actions + transform when enabled",
        type(opts.actions) == "table" and type(opts.transform) == "function")

    vim.notify = orig_notify
    config.setup({}) -- restore defaults
end

-------------------------------------------------------------------
-- Test 9: runner command resolution
-------------------------------------------------------------------
do
    local runner = require("kotlin-lite.runner")
    local base = fixtures .. "/runner"

    check("runner: gradle wrapper -> ./gradlew run",
        runner.command_for(base .. "/gradle", "project") == "./gradlew run")
    check("runner: file scope adds -PmainClass",
        runner.command_for(base .. "/gradle", "file", "com.x.MainKt")
        == "./gradlew run -PmainClass=com.x.MainKt")
    check("runner: Makefile fallback -> make run",
        runner.command_for(base .. "/make", "project") == "make run")
    check("runner: unknown root -> nil",
        runner.command_for(base .. "/nope", "project") == nil)
end

-------------------------------------------------------------------
-- Test 10: rename_file top-level entity detection
-------------------------------------------------------------------
do
    local A = require("kotlin-lite.actions")
    check("entity: data class", A._toplevel_entity({ "package p", "", "data class Foo(val x: Int)" }, "Foo") == "class")
    check("entity: interface", A._toplevel_entity({ "interface Bar {" }, "Bar") == "interface")
    check("entity: top-level fun", A._toplevel_entity({ "fun greet() {}" }, "greet") == "fun")
    check("entity: ignores indented (nested)", A._toplevel_entity({ "    class Inner" }, "Inner") == nil)
    check("entity: no prefix false-match", A._toplevel_entity({ "class FooBar" }, "Foo") == nil)
end

-------------------------------------------------------------------
-- Test 11: cross-platform clipboard command builder (Linux runner)
-------------------------------------------------------------------
do
    local snacks = require("kotlin-lite.snacks")
    local spec = snacks._clipboard_file_command({ "/tmp/A.kt", "/tmp/B.kt" })
    -- on this Linux CI box we expect a uri-list tool or nil (headless w/o DISPLAY)
    local ok = spec == nil
        or (type(spec.cmd) == "table" and spec.stdin == "file:///tmp/A.kt\nfile:///tmp/B.kt\n")
    check("clipboard: builds uri-list stdin (or nil when no tool)", ok, vim.inspect(spec))
end

-------------------------------------------------------------------
-- Test 12: rename_file moves the file end-to-end (no entity prompt)
-------------------------------------------------------------------
do
    local dir = vim.fn.fnamemodify(vim.fn.tempname(), ":h")
    local old_path = dir .. "/RenameMe.kt"
    local new_path = dir .. "/Renamed.kt"
    -- `class Other` deliberately mismatches the file name -> no entity confirm
    vim.fn.writefile({ "package t", "", "class Other" }, old_path)

    vim.cmd("edit! " .. vim.fn.fnameescape(old_path))
    vim.bo.filetype = "kotlin"

    local orig_input = vim.ui.input
    vim.ui.input = function(_, cb) cb("Renamed") end
    pcall(require("kotlin-lite.actions").rename_file)
    vim.ui.input = orig_input

    check("rename_file: buffer now on new path", bufname():match("/Renamed%.kt$") ~= nil)
    check("rename_file: new file exists", vim.fn.filereadable(new_path) == 1)
    check("rename_file: old file removed", vim.fn.filereadable(old_path) == 0)

    vim.fn.delete(old_path)
    vim.fn.delete(new_path)
end

-------------------------------------------------------------------
-- Test 13: gd is case-sensitive even when 'ignorecase' is on
-- (cursor on `Circle` must not land on the `circle` val)
-------------------------------------------------------------------
do
    vim.o.ignorecase = true
    open("Main.kt")
    local usage = line_of("Circle(radius)")
    cursor_on(usage, "Circle")
    actions.goto_definition()
    local jumped = vim.wait(4000, function()
        return bufname():match("Geometry%.kt$") ~= nil
    end, 40)
    check("gd: Circle -> class (ignorecase on, not the `circle` val)",
        jumped and vim.api.nvim_get_current_line():find("class Circle", 1, true) ~= nil)
    vim.o.ignorecase = false
end

-------------------------------------------------------------------
-- Test 14: format_buffer pipes the whole buffer through formatprg (stdout only)
-------------------------------------------------------------------
do
    local config = require("kotlin-lite.config")
    config.setup({ formatprg = "tr a-z A-Z", format_on_equal = false })

    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "package p", "class widget" })
    actions.format_buffer()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    check("format: buffer replaced by formatter stdout",
        lines[1] == "PACKAGE P" and lines[2] == "CLASS WIDGET",
        table.concat(lines, " / "))
    vim.cmd("bwipeout!")
    config.setup({})
end

-------------------------------------------------------------------
-- Test 15: usages maps (gu + grr) are buffer-local to kotlin; LSP defaults
-- remain global for other filetypes
-------------------------------------------------------------------
do
    local function bufmapped(l)
        return vim.fn.maparg(l, "n", "", true).buffer == 1
    end

    open("Main.kt")
    check("usages: gu is buffer-local in kotlin", bufmapped("gu"))
    check("usages: grr is buffer-local in kotlin", bufmapped("grr"))

    vim.cmd("enew")
    vim.bo.filetype = "lua"
    check("usages: gu NOT mapped in a lua buffer", not bufmapped("gu"))
    check("usages: default grr LSP map preserved globally", vim.fn.maparg("grr", "n") ~= "")
    vim.cmd("bwipeout!")
end

-------------------------------------------------------------------
-- Test 16: file-structure outline (scope-aware filtering)
-------------------------------------------------------------------
do
    open("Structure.kt")
    local items = actions._scan_symbols(vim.api.nvim_buf_get_lines(0, 0, -1, false))
    local kind, vis = {}, {}
    for _, it in ipairs(items) do kind[it.name], vis[it.name] = it.kind, it.vis end

    -- main hierarchy is shown regardless of visibility (private/protected too)
    local shown = { "TOP_CONST", "topVar", "topLevel", "hiddenFun", "Shape", "perimeter",
        "Point", "x", "secret", "visible", "hiddenField", "mutable", "distance", "ORIGIN" }
    for _, n in ipairs(shown) do
        check("outline: shows " .. n, kind[n] ~= nil)
    end
    -- but function locals and non-property params stay out
    for _, n in ipairs({ "localOnly", "tmp", "z" }) do
        check("outline: hides " .. n, kind[n] == nil)
    end
    check("outline: Point is a class", kind["Point"] == "class")
    check("outline: perimeter is a fun", kind["perimeter"] == "fun")
    check("outline: x is a field (ctor prop)", kind["x"] == "field")
    -- visibility recorded for the fade sigil
    check("outline: secret is private", vis["secret"] == "private")
    check("outline: hiddenField is private", vis["hiddenField"] == "private")
    check("outline: hiddenFun is private", vis["hiddenFun"] == "private")
    check("outline: visible is public", vis["visible"] == "public")
end

-------------------------------------------------------------------
-- Test 17: outline on multi-line ctor + secondary ctors (Cycle.kt)
-------------------------------------------------------------------
do
    open("Cycle.kt")
    local items = actions._scan_symbols(vim.api.nvim_buf_get_lines(0, 0, -1, false))
    local kind, count = {}, {}
    for _, it in ipairs(items) do
        kind[it.name] = it.kind
        count[it.name] = (count[it.name] or 0) + 1
    end

    -- ctor properties appear exactly once (no duplication from the param lines)
    check("cycle: inhaleUnit shown once", count["inhaleUnit"] == 1)
    check("cycle: all 7 primary-ctor props present",
        kind["type"] and kind["inhaleUnit"] and kind["retainUnit"] and kind["exhaleUnit"]
        and kind["sustainUnit"] and kind["reposeUnit"] and kind["millisPerUnit"] and true or false)
    -- public members inside the class body are shown
    for _, n in ipairs({ "isReposeCycle", "cycleMillis", "isConstantCycle", "isConstantPhase",
        "getPhaseMillis" }) do
        check("cycle: shows " .. n, kind[n] ~= nil)
    end
    check("cycle: getPhaseMillis is a fun", kind["getPhaseMillis"] == "fun")
    -- private members are now shown (with a visibility sigil); secondary-ctor
    -- params (no val/var) still stay out
    check("cycle: shows private convertToActualUnits", kind["convertToActualUnits"] == "fun")
    check("cycle: shows private unitToMillis", kind["unitToMillis"] == "fun")
    check("cycle: top-level const shown", kind["PHASE_MILLIS_FACTOR"] == "field")
    check("cycle: companion shown", kind["asConstantPhase"] ~= nil)
end

-------------------------------------------------------------------
-- Test 18: sources jar version parsing / latest-per-artifact
-------------------------------------------------------------------
do
    local jars = require("kotlin-lite.jars")

    local a1, v1 = jars._parse_nv("kotlin-stdlib-jdk8-2.2.10-sources.jar")
    check("jars: parse artifact with suffix", a1 == "kotlin-stdlib-jdk8" and v1 == "2.2.10")
    local a2, v2 = jars._parse_nv("kotlin-stdlib-2.4.0-sources.jar")
    check("jars: parse plain artifact", a2 == "kotlin-stdlib" and v2 == "2.4.0")

    check("jars: 2.2.0 < 2.10.0 (numeric)", jars._ver_lt("2.2.0", "2.10.0") == true)
    check("jars: equal versions not <", jars._ver_lt("2.4.0", "2.4.0") == false)
    check("jars: pre-release < release", jars._ver_lt("2.4.0-RC", "2.4.0") == true)

    -- distinct artifacts kept; each collapsed to its newest version
    local latest = jars._latest_by_artifact({
        "/c/kotlin-stdlib-2.0.0-sources.jar",
        "/c/kotlin-stdlib-2.2.0-sources.jar",
        "/c/kotlin-stdlib-2.4.0-sources.jar",
        "/c/kotlin-stdlib-jdk8-1.9.24-sources.jar",
    })
    local picked = {}
    for _, e in ipairs(latest) do picked[e.artifact] = e.version end
    check("jars: stdlib collapses to newest 2.4.0", picked["kotlin-stdlib"] == "2.4.0")
    check("jars: jdk8 kept as a distinct artifact", picked["kotlin-stdlib-jdk8"] == "1.9.24")
    check("jars: only 2 artifacts after collapse", vim.tbl_count(picked) == 2)
end

-------------------------------------------------------------------
-- Test 19: <leader>ks is mapped in kotlin buffers
-------------------------------------------------------------------
do
    open("Main.kt")
    check("sources: <leader>ks mapped", vim.fn.maparg("<leader>ks", "n", "", true).buffer == 1)
end

-------------------------------------------------------------------
-- Test 20: project_symbols is a single picker over TOP-LEVEL symbols only
-------------------------------------------------------------------
do
    local captured
    local orig = vim.ui.select
    vim.ui.select = function(list) captured = list end -- capture, don't invoke cb

    open("Main.kt") -- cwd is the fixtures dir -> rg scans all fixtures
    actions.project_symbols()
    vim.wait(4000, function() return captured ~= nil end, 40)
    vim.ui.select = orig

    local kind = {}
    for _, s in ipairs(captured or {}) do kind[s.data.name] = s.data.kind end

    for _, n in ipairs({ "Circle", "Shape", "Point", "CyclePhase", "CycleType",
        "CycleEntry", "topLevel", "main", "describe" }) do
        check("symbols: includes top-level " .. n, kind[n] ~= nil)
    end
    check("symbols: enum CyclePhase is a class kind", kind["CyclePhase"] == "class")
    check("symbols: object CycleType is object kind", kind["CycleType"] == "object")
    -- nested members and fields must NOT appear
    for _, n in ipairs({ "perimeter", "distance", "isReposeCycle", "asConstantPhase",
        "TOP_CONST", "inhaleUnit" }) do
        check("symbols: excludes nested/field " .. n, kind[n] == nil)
    end
end

-------------------------------------------------------------------
-- Test 21: auto-extract essential set includes test libs; compose is Android-only
-------------------------------------------------------------------
do
    local e = require("kotlin-lite.config").options.essentials
    local function has(list, v)
        for _, x in ipairs(list) do if x == v then return true end end
        return false
    end
    check("essentials: kotlin has stdlib", has(e.kotlin, "kotlin-stdlib"))
    check("essentials: test has junit + kotlin-test", has(e.test, "junit") and has(e.test, "kotlin-test"))
    check("essentials: compose has material3 + ui", has(e.compose, "material3") and has(e.compose, "ui"))
end

-------------------------------------------------------------------
-- Test 22: attach_globals exposes only the <leader>k menu (global, not buffer)
-------------------------------------------------------------------
do
    -- observe from a non-kotlin buffer so buffer-local maps don't shadow globals
    vim.cmd("enew")
    vim.bo.filetype = "lua"
    local km = require("kotlin-lite.keymaps")
    km.attach_globals(km.project_actions) -- simulate being in a gradle project

    local function g(l)
        local m = vim.fn.maparg(l, "n", "", true)
        return next(m) ~= nil and m.buffer == 0
    end
    -- project-level menu is global
    check("globals: <leader>ks (sources) global", g("<leader>ks"))
    check("globals: <leader>kR (run_project) global", g("<leader>kR"))
    check("globals: <leader>ke (reveal) global", g("<leader>ke"))
    -- snacks compact toggle was registered globally at init (snacks_integration)
    check("globals: <leader>km (toggle_compact) global", g("<leader>km"))
    -- kt-specific & navigation maps must NOT be global
    check("globals: <leader>kr (run_file) NOT global", vim.fn.maparg("<leader>kr", "n") == "")
    check("globals: <leader>ka (alternate) NOT global", vim.fn.maparg("<leader>ka", "n") == "")
    check("globals: gd NOT global", vim.fn.maparg("gd", "n") == "")
    check("globals: <leader>cs NOT global", vim.fn.maparg("<leader>cs", "n") == "")

    for _, l in ipairs({ "<leader>ks", "<leader>kR", "<leader>ke" }) do
        pcall(vim.keymap.del, "n", l)
    end
    vim.cmd("bwipeout!")
end

-------------------------------------------------------------------
-- Test 23: gr*/gO aliases are buffer-local in kotlin buffers
-------------------------------------------------------------------
do
    open("Main.kt")
    local function bl(l) return vim.fn.maparg(l, "n", "", true).buffer == 1 end
    check("alias: grn -> rename", bl("grn"))
    check("alias: grt -> definition", bl("grt"))
    check("alias: gra -> auto-import", bl("gra"))
    check("alias: gO -> file structure", bl("gO"))
    check("alias: grr -> usages", bl("grr"))
end

-------------------------------------------------------------------
-- Test 24: project globals attach on entering a gradle-project file
-------------------------------------------------------------------
do
    pcall(vim.keymap.del, "n", "<leader>kR") -- ensure a clean starting point
    vim.cmd("edit " .. vim.fn.fnameescape(fixtures .. "/runner/gradle/build.gradle.kts"))
    vim.wait(500, function() return vim.fn.maparg("<leader>kR", "n") ~= "" end, 20)
    check("project: entering a gradle file attaches <leader>kR globally",
        vim.fn.maparg("<leader>kR", "n") ~= "")
end

-------------------------------------------------------------------
-- Test 25: gradle test command construction
-------------------------------------------------------------------
do
    local runner = require("kotlin-lite.runner")
    local cmd = runner.test_command(fixtures .. "/runner/gradle", { "test" }, "com.x.FooTest")
    check("test: uses gradle wrapper", cmd:match("^%./gradlew ") ~= nil)
    check("test: plain console", cmd:find("--console=plain", 1, true) ~= nil)
    check("test: injects init script", cmd:find("--init-script", 1, true) ~= nil)
    check("test: filters to the class", cmd:find("--tests", 1, true) ~= nil
        and cmd:find("com.x.FooTest", 1, true) ~= nil)

    local mcmd = runner.test_command(fixtures .. "/runner/gradle",
        { ":app:test", ":core:data:jvmTest" }, nil)
    check("test: multi-module specs joined", mcmd:find(":app:test :core:data:jvmTest", 1, true) ~= nil)

    -- task detection: source set from the file path wins
    check("test_task: src/commonTest file -> jvmTest",
        runner.test_task(fixtures, "/x/core/data/src/commonTest/kotlin/FooTest.kt") == "jvmTest")
    check("test_task: src/jvmTest file -> jvmTest",
        runner.test_task(fixtures, "/x/m/src/jvmTest/kotlin/FooTest.kt") == "jvmTest")
    check("test_task: src/test file -> test",
        runner.test_task(fixtures, "/x/app/src/test/java/FooTest.java") == "test")
    -- else fall back to module structure / build script
    check("test_task: plain project -> test",
        runner.test_task(fixtures .. "/runner/gradle") == "test")
    check("test_task: KMP build script (case-insensitive) -> jvmTest",
        runner.test_task(fixtures .. "/runner/kmp") == "jvmTest")
end

-------------------------------------------------------------------
-- Test 26: settings.gradle module discovery
-------------------------------------------------------------------
do
    local mods = require("kotlin-lite.runner").modules(fixtures .. "/runner/multimodule")
    local set = {}
    for _, m in ipairs(mods) do set[m] = true end
    check("modules: finds :app", set[":app"])
    check("modules: finds :core", set[":core"])
    check("modules: finds :feature:login", set[":feature:login"])
    check("modules: does not pick rootProject.name", not set["demo"])

    local runner = require("kotlin-lite.runner")
    local mm = fixtures .. "/runner/multimodule"
    check("module_of: file in app/ -> :app",
        runner.module_of(mm, mm .. "/app/src/test/kotlin/FooTest.kt") == ":app")
    check("module_of: file in root project -> nil",
        runner.module_of(mm, mm .. "/FooTest.kt") == nil)
end

-------------------------------------------------------------------
-- Test 27: JUnit XML failures -> quickfix items
-------------------------------------------------------------------
do
    local items = require("kotlin-lite.runner").parse_failures(fixtures .. "/testresults", nil)
    check("failures: exactly one failed testcase", #items == 1)
    local it = items[1] or {}
    check("failures: names the failed test", (it.text or ""):find("fixtures.SampleTest.fails", 1, true) ~= nil)
    check("failures: unescapes the message", (it.text or ""):find("expected:<1> but was:<2>", 1, true) ~= nil)
    check("failures: keeps the source line", it.lnum == 12 or (it.text or ""):find("SampleTest.kt", 1, true) ~= nil)
end

-------------------------------------------------------------------
-- Test 28: test keymaps (kt-local <leader>kt, global <leader>kT)
-------------------------------------------------------------------
do
    open("Main.kt")
    check("test: <leader>kt buffer-local in kotlin",
        vim.fn.maparg("<leader>kt", "n", "", true).buffer == 1)
    check("test: test_project is a project global action",
        vim.tbl_contains(require("kotlin-lite.keymaps").project_actions, "test_project"))
end

-------------------------------------------------------------------
io.write("\n")
if failures == 0 then
    io.write("All checks passed.\n")
    vim.cmd("qall!")
else
    io.write(failures .. " check(s) failed.\n")
    vim.cmd(failures .. "cquit!")
end
