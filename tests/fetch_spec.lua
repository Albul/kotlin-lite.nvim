-- gd on a class of a library without extracted sources: find / download its
-- -sources.jar (gradle cache first, then gradle itself), extract, jump.

local h = require("helpers")
local fetch = require("kotlin-lite.fetch")
local config = require("kotlin-lite.config")
local actions = require("kotlin-lite.actions")

local USES = "fetch/Uses.kt"
local SRC = "commonMain/com/example/remote/core/RemoteWidget.kt"

-- a -sources.jar at `path` with `files` ({ [entry] = lines })
local function make_jar(path, files)
    local src = vim.fn.tempname()
    for entry, lines in pairs(files) do
        vim.fn.mkdir(vim.fs.dirname(src .. "/" .. entry), "p")
        vim.fn.writefile(lines, src .. "/" .. entry)
    end
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.system({ "zip", "-q", "-r", path, "." }, { cwd = src }):wait()
    vim.fn.delete(src, "rf")
    return path
end

local WIDGET = { [SRC] = {
    "package com.example.remote.core", "", "open class RemoteWidget", "",
    "fun remoteHelper() = Unit", "", "const val MAX_WIDGETS = 3",
} }

-- gradle-cache path of a sources jar
local function cached_path(root, group, artifact, version)
    return ("%s/%s/%s/%s/0123abcd/%s-%s-sources.jar"):format(root, group, artifact, version, artifact, version)
end

describe("fetch.target", function()
    it("package + class -> the .class entry to look for", function()
        assert.are.same({
            pkg = "com.example.remote.core", dir = "com/example/remote/core/",
            entry = "com/example/remote/core/RemoteWidget.class",
        }, fetch.target("com.example.remote.core", "RemoteWidget"))
    end)
    it("a nested class -> its outermost class", function()
        assert.are.same({
            pkg = "com.example.remote.core", dir = "com/example/remote/core/",
            entry = "com/example/remote/core/Outer.class",
        }, fetch.target("com.example.remote.core.Outer", "Inner"))
    end)
    it("a top-level fun / val (in some FileKt.class) -> the package only", function()
        assert.are.same({ pkg = "androidx.activity", dir = "androidx/activity/" },
            fetch.target("androidx.activity", "enableEdgeToEdge"))
    end)
    it("a top-level CONSTANT -> the package only", function()
        assert.are.same({ pkg = "com.example.remote.core", dir = "com/example/remote/core/" },
            fetch.target("com.example.remote.core", "MAX_WIDGETS"))
    end)
    it("a one-letter class is a class", function()
        assert.are.equal("a/b/X.class", fetch.target("a.b", "X").entry)
    end)
    it("no package -> nil", function()
        assert.is_nil(fetch.target(nil, "RemoteWidget"))
    end)
    it("JDK / android platform packages -> nil (not on a gradle classpath)", function()
        assert.is_nil(fetch.target("java.time", "Instant"))
        assert.is_nil(fetch.target("javax.inject", "Inject"))
        assert.is_nil(fetch.target("android.os", "Bundle"))
    end)
end)

describe("fetch.parse", function()
    it("sources jar paths, noise ignored", function()
        assert.are.same({ sources = { "/c/a-1.0-sources.jar" }, missing = {} }, fetch.parse({
            "> Configure project :",
            "KL-SOURCES /c/a-1.0-sources.jar",
            "KL-SOURCES /c/a-1.0-sources.jar",
        }))
    end)
    it("a class with no published sources", function()
        assert.are.same({ sources = {}, nosources = "g:a:1.0", missing = { "g:a:1.0" } },
            fetch.parse({ "KL-NOSOURCES g:a:1.0" }))
    end)
    it("every library without sources, once", function()
        assert.are.same({ "g:a:1.0", "g:b:2.0" },
            fetch.parse({ "KL-NOSOURCES g:a:1.0", "KL-NOSOURCES g:b:2.0", "KL-NOSOURCES g:a:1.0" }).missing)
    end)
    it("a class on no classpath", function()
        assert.are.same({ sources = {}, missing = {}, noclass = true }, fetch.parse({ "KL-NOCLASS" }))
    end)
end)

describe("fetch.command", function()
    local root = h.fixtures .. "/fetch"
    local class = { pkg = "com.x", dir = "com/x/", entry = "com/x/A.class" }

    it("runs the init-script task for the class, quietly, without the configuration cache", function()
        local s = table.concat(fetch.command(root, class), " ")
        assert.is_truthy(s:find("--init-script ", 1, true))
        assert.is_truthy(s:find(" :klSources ", 1, true))
        assert.is_truthy(s:find("-Pkl.class=com/x/A.class", 1, true))
        assert.is_truthy(s:find("-Pkl.pkg=com/x/", 1, true))
        assert.is_truthy(s:find("--no-configuration-cache", 1, true))
        assert.is_truthy(s:find("-q", 1, true))
    end)
    it("only in the module of the file", function()
        local s = table.concat(fetch.command(root, class, ":feature:login"), " ")
        assert.is_truthy(s:find(" :feature:login:klSources ", 1, true))
    end)
    it("a package only: no class", function()
        local s = table.concat(fetch.command(root, { pkg = "com.x", dir = "com/x/" }), " ")
        assert.is_truthy(s:find("-Pkl.pkg=com/x/", 1, true))
        assert.is_falsy(s:find("kl.class", 1, true))
    end)
    it("the init script resolves the sources classifier, looks into an aar's classes.jar", function()
        local cmd = fetch.command(root, class)
        local i = vim.fn.index(cmd, "--init-script")
        assert.is_true(i >= 0)
        local script = table.concat(vim.fn.readfile(cmd[i + 2]), "\n")
        assert.is_truthy(script:find("klSources", 1, true))
        assert.is_truthy(script:find(":sources@jar", 1, true))
        assert.is_truthy(script:find(".aar", 1, true))
        assert.is_truthy(script:find("classes.jar", 1, true))
    end)
end)

describe("fetch.sync_command", function()
    it("the all-projects task, carrying on past a failing project", function()
        local cmd = fetch.sync_command(h.fixtures .. "/fetch")
        assert.are.equal("klSourcesAll", cmd[#cmd])
        assert.is_true(vim.tbl_contains(cmd, "--continue"))
        assert.is_true(vim.tbl_contains(cmd, "--no-configuration-cache"))
        local script = table.concat(vim.fn.readfile(cmd[vim.fn.index(cmd, "--init-script") + 2]), "\n")
        assert.is_truthy(script:find('tasks.register("klSourcesAll")', 1, true))
    end)
end)

describe("fetch.cached", function()
    local tmp
    before_each(function() tmp = vim.fn.tempname() end)
    after_each(function() vim.fn.delete(tmp, "rf") end)

    it("the newest sources jar of the group that has the package", function()
        make_jar(cached_path(tmp, "com.example.remote", "remote-core-jvm", "1.0.0"), WIDGET)
        local new = make_jar(cached_path(tmp, "com.example.remote", "remote-core-jvm", "1.2.0"), WIDGET)
        make_jar(cached_path(tmp, "com.example.remote", "remote-other", "1.0.0"),
            { ["com/example/remote/other/X.kt"] = { "package com.example.remote.other" } })
        assert.are.same({ new }, fetch.cached("com.example.remote.core", { tmp }))
    end)
    it("nothing for a package no group is a prefix of", function()
        make_jar(cached_path(tmp, "com.example.remote", "remote-core-jvm", "1.0.0"), WIDGET)
        assert.are.same({}, fetch.cached("org.other.core", { tmp }))
    end)
end)

describe("gd on a class without extracted sources", function()
    local tmp, gradle, runs, cap

    local function gd_in(file, needle, word)
        cap = h.capture_notify()
        h.open(file)
        h.cursor_at(needle, word)
        actions.goto_definition()
    end
    local function gd(needle, word) gd_in(USES, needle, word) end

    before_each(function()
        tmp = vim.fn.tempname()
        gradle = tmp .. "/gradle"
        config.setup({ cache_dir = tmp .. "/cache", jar_search_roots = { gradle } })
        require("kotlin-lite.jars").scan_cache()
        fetch.reset()
        runs = {}
        -- gradle is never run for real: each test says what it answers
        h.stub(fetch, "run", function(cmd, cwd, cb)
            runs[#runs + 1] = { cmd = cmd, cwd = cwd }
            cb({ "KL-NOCLASS" })
        end)
    end)
    after_each(function()
        h.reset()
        require("kotlin-lite.jars").scan_cache()
        vim.fn.delete(tmp, "rf")
    end)

    it("sources in the gradle cache: extracted and jumped to, gradle not run", function()
        make_jar(cached_path(gradle, "com.example.remote", "remote-core-jvm", "1.0.0"), WIDGET)
        gd("import com.example.remote.core.RemoteWidget", "RemoteWidget")
        assert.is_true(h.wait(function() return h.bufname():find("RemoteWidget.kt", 1, true) ~= nil end))
        assert.are.equal(0, #runs)
        assert.are.equal(3, h.cur_line())
    end)

    it("from the use site, not only the import line", function()
        make_jar(cached_path(gradle, "com.example.remote", "remote-core-jvm", "1.0.0"), WIDGET)
        gd("class Uses", "RemoteWidget")
        assert.is_true(h.wait(function() return h.bufname():find("RemoteWidget.kt", 1, true) ~= nil end))
    end)

    it("not cached: gradle downloads it, then the jump", function()
        local jar = tmp .. "/downloaded/remote-core-jvm-1.0.0-sources.jar"
        h.stub(fetch, "run", function(cmd, cwd, cb)
            runs[#runs + 1] = { cmd = cmd, cwd = cwd }
            make_jar(jar, WIDGET)
            cb({ "KL-SOURCES " .. jar })
        end)
        gd("import com.example.remote.core.RemoteWidget", "RemoteWidget")
        assert.is_true(h.wait(function() return h.bufname():find("RemoteWidget.kt", 1, true) ~= nil end))
        assert.are.equal(1, #runs)
        assert.are.equal(h.fixtures .. "/fetch", runs[1].cwd)
        assert.is_truthy(table.concat(runs[1].cmd, " "):find("com/example/remote/core/RemoteWidget.class", 1, true))
    end)

    it("a top-level fun: gradle is asked by package, then the jump", function()
        local jar = tmp .. "/downloaded/remote-core-jvm-1.0.0-sources.jar"
        h.stub(fetch, "run", function(cmd, cwd, cb)
            runs[#runs + 1] = { cmd = cmd, cwd = cwd }
            make_jar(jar, WIDGET)
            cb({ "KL-SOURCES " .. jar })
        end)
        gd("import com.example.remote.core.remoteHelper", "remoteHelper")
        assert.is_true(h.wait(function() return h.bufname():find("RemoteWidget.kt", 1, true) ~= nil end))
        assert.are.equal(5, h.cur_line())
        local s = table.concat(runs[1].cmd, " ")
        assert.is_truthy(s:find("-Pkl.pkg=com/example/remote/core/", 1, true))
        assert.is_falsy(s:find("kl.class", 1, true))
    end)

    it("in a module: gradle runs the task of that module only", function()
        gd_in("fetch/app/Screen.kt", "import com.example.remote.core.RemoteWidget", "RemoteWidget")
        assert.is_true(h.wait(function() return #runs > 0 end))
        assert.are.equal(h.fixtures .. "/fetch", runs[1].cwd)
        assert.is_truthy(table.concat(runs[1].cmd, " "):find(" :app:klSources ", 1, true))
    end)

    it("no sources published: says so, and doesn't ask gradle again", function()
        h.stub(fetch, "run", function(cmd, cwd, cb)
            runs[#runs + 1] = { cmd = cmd, cwd = cwd }
            cb({ "KL-NOSOURCES com.example.remote:remote-core-jvm:1.0.0" })
        end)
        gd("import com.example.remote.core.RemoteWidget", "RemoteWidget")
        assert.is_true(h.wait(function() return (cap.msg or ""):find("no sources published", 1, true) ~= nil end))
        assert.is_truthy(cap.msg:find("com.example.remote:remote-core-jvm:1.0.0", 1, true))
        assert.are.equal(USES, h.relname())

        gd("import com.example.remote.core.RemoteWidget", "RemoteWidget")
        assert.is_true(h.wait(function() return (cap.msg or ""):find("no sources published", 1, true) ~= nil end))
        assert.are.equal(1, #runs)
    end)

    it("a class on no classpath: the usual message", function()
        gd("import com.example.remote.core.RemoteWidget", "RemoteWidget")
        assert.is_true(h.wait(function() return (cap.msg or ""):find("no declaration of 'RemoteWidget'", 1, true) ~= nil end))
        assert.are.equal(1, #runs)
    end)

    it("a package of the project: no download", function()
        gd("import fetchfix.local.Missing", "Missing")
        assert.is_true(h.wait(function() return (cap.msg or ""):find("no declaration of 'Missing'", 1, true) ~= nil end))
        assert.are.equal(0, #runs)
    end)

    it("a JDK class: no download", function()
        gd("import java.time.Instant", "Instant")
        assert.is_true(h.wait(function() return cap.msg ~= nil end))
        assert.are.equal(0, #runs)
    end)
end)

describe(":KotlinSourcesSync", function()
    local jars = require("kotlin-lite.jars")
    local ROOT = h.fixtures .. "/fetch"
    local tmp, runs, cap, answer, code

    local OTHER = { ["com/example/other/Other.kt"] = { "package com.example.other", "", "class Other" } }

    local function sync(quiet)
        local done
        fetch.sync(ROOT, quiet, function(ok) done = { ok } end)
        assert.is_true(h.wait(function() return done ~= nil end))
        return done[1]
    end
    local function names(dirs)
        local out = vim.tbl_map(function(d) return jars.jar_label(d) end, dirs)
        table.sort(out)
        return out
    end

    before_each(function()
        tmp = vim.fn.tempname()
        config.setup({ cache_dir = tmp .. "/cache", jar_search_roots = {}, auto_sync = true })
        jars.scan_cache()
        fetch.reset()
        cap = h.capture_notify()
        runs, code = {}, 0
        answer = {
            "KL-SOURCES " .. make_jar(tmp .. "/g/remote-core-jvm-1.0.0-sources.jar", WIDGET),
            "KL-SOURCES " .. make_jar(tmp .. "/g/remote-other-2.0.0-sources.jar", OTHER),
            "KL-NOSOURCES com.example:closed:1.0",
        }
        h.stub(fetch, "run", function(cmd, cwd, cb)
            runs[#runs + 1] = { cmd = cmd, cwd = cwd }
            cb(answer, code, code == 0 and "" or "FAILURE: Build failed")
        end)
    end)
    after_each(function()
        h.reset()
        jars.scan_cache()
        vim.fn.delete(tmp, "rf")
    end)

    it("extracts the sources of the whole classpath, says how many", function()
        assert.is_true(sync())
        assert.are.equal(ROOT, runs[1].cwd)
        assert.are.equal("klSourcesAll", runs[1].cmd[#runs[1].cmd])
        assert.are.same({ "remote-core-jvm-1.0.0-sources.jar", "remote-other-2.0.0-sources.jar" },
            names(jars.jar_dirs()))
        assert.is_truthy(cap.msg:find("sources of 2 libraries, 2 new, 1 published none", 1, true), cap.msg)
    end)
    it("then the project sees its classpath only", function()
        local stray = make_jar(tmp .. "/g/stray-1.0-sources.jar", OTHER)
        local done
        jars.extract_jar(stray, true, function() done = true end)
        assert.is_true(h.wait(function() return done end))
        sync()
        assert.are.same({ "remote-core-jvm-1.0.0-sources.jar", "remote-other-2.0.0-sources.jar" },
            names(jars.project_dirs(ROOT .. "/" .. "Uses.kt")))
        -- outside the build: every one
        assert.are.equal(3, #jars.project_dirs(vim.fn.tempname() .. "/X.kt"))
    end)
    it("a second sync: nothing new", function()
        sync()
        sync()
        assert.is_truthy(cap.msg:find("2 libraries, 0 new", 1, true), cap.msg)
    end)
    it("quiet (the automatic one): no word when nothing is new", function()
        sync(true)
        cap.msg = nil
        sync(true)
        assert.is_nil(cap.msg)
    end)
    it("gradle fails: says why, no classpath recorded", function()
        answer, code = {}, 1
        assert.is_false(sync())
        assert.is_truthy(cap.msg:find("Build failed", 1, true), cap.msg)
        assert.is_nil(jars.classpath(ROOT))
    end)
    it("a project fails: the others' sources, no classpath recorded", function()
        code = 1
        assert.is_false(sync())
        assert.are.equal(2, #jars.jar_dirs())
        assert.is_nil(jars.classpath(ROOT))
        assert.is_truthy(cap.msg:find("Build failed", 1, true), cap.msg)
    end)

    describe("stale", function()
        it("never synced", function()
            assert.is_true(fetch.stale(ROOT))
        end)
        it("synced after the last change of a build script: no", function()
            sync()
            assert.is_false(fetch.stale(ROOT))
        end)
        it("a build script changed since", function()
            sync()
            local f = tmp .. "/cache/.classpath/" .. vim.fn.sha256(ROOT)
            vim.uv.fs_utime(f, 1, 1)
            assert.is_true(fetch.stale(ROOT))
        end)
    end)

    describe("auto_sync", function()
        it("from a module dir: syncs the build, once while it's fresh", function()
            fetch.auto_sync(ROOT .. "/app")
            assert.is_true(h.wait(function() return jars.classpath(ROOT) ~= nil and #jars.jar_dirs() == 2 end))
            fetch.auto_sync(ROOT .. "/app")
            assert.are.equal(1, #runs)
        end)
        it("off", function()
            config.setup({ cache_dir = tmp .. "/cache", auto_sync = false })
            fetch.auto_sync(ROOT)
            assert.are.equal(0, #runs)
        end)
        it("the old auto_extract = false turns it off too", function()
            config.setup({ cache_dir = tmp .. "/cache", auto_extract = false })
            fetch.auto_sync(ROOT)
            assert.are.equal(0, #runs)
        end)
        it("outside a gradle build: nothing", function()
            fetch.auto_sync(vim.fn.tempname())
            assert.are.equal(0, #runs)
        end)
    end)

    it("gd on a library added since the sync: onto the classpath, jumped to, no gradle", function()
        local gradle = tmp .. "/gradle"
        config.setup({ cache_dir = tmp .. "/cache", jar_search_roots = { gradle } })
        jars.record_classpath(ROOT, { tmp .. "/g/unrelated-1.0-sources.jar" }, true)
        local jar = make_jar(cached_path(gradle, "com.example.remote", "remote-core-jvm", "1.0.0"), WIDGET)
        local done
        jars.extract_jar(jar, true, function() done = true end)
        assert.is_true(h.wait(function() return done end))
        h.open(USES)
        h.cursor_at("import com.example.remote.core.RemoteWidget", "RemoteWidget")
        actions.goto_definition()
        assert.is_true(h.wait(function() return h.bufname():find("RemoteWidget.kt", 1, true) ~= nil end))
        assert.are.equal(0, #runs)
        assert.is_true(vim.tbl_contains(jars.classpath(ROOT), jar))
    end)
end)
