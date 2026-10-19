-- JDK sources for JVM code: lib/src.zip of the JDK the build's toolchain asks
-- for (else $JAVA_HOME, else the newest installed), java.* / javax.* only.

local h = require("helpers")
local sdk = require("kotlin-lite.sdk")
local jars = require("kotlin-lite.jars")
local config = require("kotlin-lite.config")
local actions = require("kotlin-lite.actions")

local tests_dir = vim.fn.fnamemodify(h.fixtures, ":h")
local SERVER = "jdk/server/src/main/kotlin/jdkdemo/Server.kt"

local tmp, saved_roots, saved_home

-- a JDK home `<tmp>/jdks/<version>` with release + lib/src.zip
local function make_jdk(version)
    local home = tmp .. "/jdks/" .. version
    vim.fn.mkdir(home .. "/lib", "p")
    vim.fn.writefile({ 'IMPLEMENTOR="Test"', ('JAVA_VERSION="%s"'):format(version) }, home .. "/release")
    vim.system({ "zip", "-q", "-r", home .. "/lib/src.zip", "." }, { cwd = tests_dir .. "/sdk/jdk" }):wait()
    return home
end

local function setup(versions, opts)
    tmp = vim.fn.tempname()
    for _, v in ipairs(versions) do make_jdk(v) end
    saved_roots, saved_home = sdk.JDK_ROOTS, vim.env.JAVA_HOME
    sdk.JDK_ROOTS = { tmp .. "/jdks" }
    vim.env.JAVA_HOME = nil
    config.setup(vim.tbl_extend("force",
        { jdk = true, android_sdk = false, cache_dir = tmp .. "/cache", jar_search_roots = {} }, opts or {}))
    jars.scan_cache()
    sdk.reset()
end
local function teardown()
    h.reset()
    sdk.JDK_ROOTS, vim.env.JAVA_HOME = saved_roots, saved_home
    sdk.reset()
    jars.scan_cache()
    vim.fn.delete(tmp, "rf")
end

describe("sdk.toolchain", function()
    it("the forms a build script can take", function()
        assert.are.equal(17, sdk._parse_toolchain({ "kotlin { jvmToolchain(17) }" }))
        assert.are.equal(21, sdk._parse_toolchain({ "languageVersion = JavaLanguageVersion.of(21)" }))
        assert.are.equal(11, sdk._parse_toolchain({ "jvmTarget.set(JvmTarget.JVM_11)" }))
        assert.are.equal(8, sdk._parse_toolchain({ "sourceCompatibility = JavaVersion.VERSION_1_8" }))
        assert.are.equal(17, sdk._parse_toolchain({ "targetCompatibility = JavaVersion.VERSION_17" }))
        assert.is_nil(sdk._parse_toolchain({ "plugins { }" }))
    end)
end)

describe("sdk.jdk", function()
    after_each(teardown)

    it("the toolchain's JDK", function()
        setup({ "17.0.9", "21.0.3" })
        local j = sdk.jdk(h.fixtures .. "/" .. SERVER)
        assert.are.equal(17, j.major)
        assert.are.equal(17, j.want)
    end)
    it("no such JDK: the nearest newer", function()
        setup({ "21.0.3", "25.0.1" })
        assert.are.equal(21, sdk.jdk(h.fixtures .. "/" .. SERVER).major)
    end)
    it("no toolchain: $JAVA_HOME", function()
        setup({ "17.0.9", "21.0.3" })
        vim.env.JAVA_HOME = tmp .. "/jdks/17.0.9"
        assert.are.equal(17, sdk.jdk(h.fixtures .. "/jdk/kmp/src/jvmMain/kotlin/jdkdemo/Jvm.kt").major)
    end)
    it("no toolchain, no $JAVA_HOME: the newest", function()
        setup({ "17.0.9", "21.0.3" })
        assert.are.equal(21, sdk.jdk(h.fixtures .. "/jdk/kmp/src/jvmMain/kotlin/jdkdemo/Jvm.kt").major)
    end)
    it("jdk = <home>: that one", function()
        setup({ "17.0.9", "21.0.3" })
        config.setup({ jdk = tmp .. "/jdks/21.0.3", android_sdk = false, cache_dir = tmp .. "/cache" })
        assert.are.equal(21, sdk.jdk(h.fixtures .. "/" .. SERVER).major)
    end)
    it("jdk = false: none", function()
        setup({ "17.0.9" })
        config.setup({ jdk = false, cache_dir = tmp .. "/cache" })
        assert.is_nil(sdk.jdk(h.fixtures .. "/" .. SERVER))
        assert.are.same({}, sdk.dirs(h.fixtures .. "/" .. SERVER))
    end)
end)

describe("sdk.dirs for JVM code", function()
    after_each(teardown)
    before_each(function() setup({ "17.0.9" }) end)

    it("java.* / javax.* of the JDK's modules, nothing internal", function()
        local dirs = sdk.dirs(h.fixtures .. "/" .. SERVER)
        assert.are.equal(1, #dirs)
        assert.are.equal(1, vim.fn.filereadable(dirs[1] .. "/java.base/java/lang/Thread.java"))
        assert.are.equal(1, vim.fn.filereadable(dirs[1] .. "/java.sql/java/sql/Connection.java"))
        assert.are.equal(0, vim.fn.isdirectory(dirs[1] .. "/java.base/jdk"))
    end)
    it("a KMP module: jvmMain yes, commonMain no", function()
        assert.are.equal(1, #sdk.dirs(h.fixtures .. "/jdk/kmp/src/jvmMain/kotlin/jdkdemo/Jvm.kt"))
        assert.are.same({}, sdk.dirs(h.fixtures .. "/jdk/kmp/src/commonMain/kotlin/jdkdemo/Common.kt"))
    end)
    it("android code: not the JDK", function()
        assert.are.same({}, sdk.dirs(h.fixtures .. "/jdk/app/src/main/kotlin/jdkdemo/App.kt"))
    end)
end)

describe("gd into the JDK", function()
    local cap

    local function gd(file, needle, word)
        cap = h.capture_notify()
        local sel = h.capture_select()
        h.open(file)
        h.cursor_at(needle, word)
        local buf = h.bufname()
        actions.goto_definition()
        h.wait(function() return h.bufname() ~= buf or sel.list ~= nil or cap.msg ~= nil end)
        assert.is_nil(sel.list and h.format_rows(sel), "picker opened instead of a jump")
    end
    local function assert_in(rel, needle)
        assert.is_truthy(h.bufname():sub(-#rel) == rel, "in " .. h.bufname())
        assert.is_truthy(vim.api.nvim_get_current_line():find(needle, 1, true), vim.api.nvim_get_current_line())
    end

    after_each(teardown)

    describe("the toolchain's JDK installed", function()
        before_each(function() setup({ "17.0.9", "21.0.3" }) end)

        it("an imported class", function()
            gd(SERVER, "fun jdkNow()", "Instant")
            assert_in("java.base/java/time/Instant.java", "public final class Instant")
            assert.is_truthy(h.bufname():find("jdk-17.0.9", 1, true))
        end)
        it("a static method", function()
            gd(SERVER, "fun jdkNow()", "now")
            assert_in("java/time/Instant.java", "public static Instant now()")
        end)
        it("another module of the JDK: java.sql", function()
            gd(SERVER, "import java.sql.Connection", "Connection")
            assert_in("java.sql/java/sql/Connection.java", "public interface Connection")
        end)
        it("java.lang without an import", function()
            gd(SERVER, "fun jdkWorker()", "Thread")
            assert_in("java/lang/Thread.java", "public class Thread")
        end)
        it("read-only, labelled by the JDK", function()
            gd(SERVER, "fun jdkWorker()", "Thread")
            assert.is_false(vim.bo.modifiable)
            assert.are.equal("[jdk-17] java/lang/Thread.java", sdk.label(h.bufname()))
        end)
        it("the exact JDK: no note", function()
            gd(SERVER, "fun jdkWorker()", "Thread")
            assert.is_nil(cap.msg)
        end)
        it("kotlin.String over java.lang.String", function()
            local dir = tmp .. "/cache/stdlib"
            vim.fn.mkdir(dir .. "/commonMain/kotlin", "p")
            vim.fn.writefile({ "package kotlin", "", "public class String : Comparable<String>, CharSequence {", "}" },
                dir .. "/commonMain/kotlin/String.kt")
            vim.fn.writefile({ "kotlin-stdlib-2.4.0-sources.jar" }, dir .. "/.jarname")
            vim.fn.writefile({}, dir .. "/.extracted")
            jars.scan_cache()
            gd(SERVER, "fun jdkName()", "String")
            assert_in("commonMain/kotlin/String.kt", "public class String")
        end)
        it("kotlin.Exception (the jvm actual typealias) over java.lang.Exception", function()
            local dir = tmp .. "/cache/stdlib"
            vim.fn.mkdir(dir .. "/commonMain/kotlin", "p")
            vim.fn.mkdir(dir .. "/jvmMain/kotlin", "p")
            vim.fn.writefile({ "package kotlin", "", "public expect open class Exception : Throwable {", "}" },
                dir .. "/commonMain/kotlin/ExceptionsH.kt")
            vim.fn.writefile({ "package kotlin", "",
                '@SinceKotlin("1.1") public actual typealias Exception = java.lang.Exception' },
                dir .. "/jvmMain/kotlin/TypeAliases.kt")
            vim.fn.writefile({ "kotlin-stdlib-2.4.0-sources.jar" }, dir .. "/.jarname")
            vim.fn.writefile({}, dir .. "/.extracted")
            jars.scan_cache()
            gd(SERVER, "fun jdkFail()", "Exception")
            assert_in("jvmMain/kotlin/TypeAliases.kt", "actual typealias Exception")
        end)
        it("a member of a Java type Kotlin maps to its own: no candidate", function()
            gd(SERVER, "fun jdkLength()", "length")
            assert.are.equal(SERVER, h.relname())
        end)
        it("common code doesn't see the JDK", function()
            gd("jdk/kmp/src/commonMain/kotlin/jdkdemo/Common.kt", "fun jdkCommon()", "Thread")
            assert.are.equal("jdk/kmp/src/commonMain/kotlin/jdkdemo/Common.kt", h.relname())
        end)
    end)

    describe("another JDK than the toolchain's", function()
        before_each(function() setup({ "21.0.3" }) end)

        it("said once per session", function()
            gd(SERVER, "fun jdkWorker()", "Thread")
            assert.is_true(h.wait(function() return cap.msg ~= nil end))
            assert.is_truthy(cap.msg:find("JDK 21", 1, true), cap.msg)
            assert.is_truthy(cap.msg:find("toolchain 17", 1, true), cap.msg)
            gd(SERVER, "fun jdkNow()", "Instant")
            assert.is_nil(cap.msg)
        end)
    end)
end)
