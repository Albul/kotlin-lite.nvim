-- One version of each library per project: the one the build pins, else the
-- newest; platform variants (-android, -desktop, ...) only where they fit;
-- the same file shipped by several related dirs counts once.

local h = require("helpers")
local jars = require("kotlin-lite.jars")
local defs = require("kotlin-lite.defs")
local config = require("kotlin-lite.config")
local actions = require("kotlin-lite.actions")

local GRADLE = "/g/caches/modules-2/files-2.1"

-- an extracted sources jar of `group`: `files` = { rel = lines } (nil: one
-- file in package `group`; false: none)
local tmp
local function lib(group, base, files)
    if files == nil then files = { ["commonMain/Lib.kt"] = { "package " .. group, "", "class Lib" } } end
    local artifact, version = jars._parse_nv(base)
    local path = ("%s/%s/%s/%s/0abc/%s"):format(GRADLE, group, artifact, version, base)
    local dir = tmp .. "/cache/" .. vim.fn.sha256(path)
    vim.fn.mkdir(dir, "p")
    for rel, lines in pairs(files or {}) do
        vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. rel), "p")
        vim.fn.writefile(lines, dir .. "/" .. rel)
    end
    vim.fn.writefile({ base }, dir .. "/.jarname")
    vim.fn.writefile({ path }, dir .. "/.jarpath")
    vim.fn.writefile({}, dir .. "/.extracted")
    return dir
end

local function setup()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/cache", "p")
    config.setup({ cache_dir = tmp .. "/cache", jar_search_roots = {} })
    jars.scan_cache()
end
local function teardown()
    h.reset()
    jars.scan_cache()
    vim.fn.delete(tmp, "rf")
end

-- the jar names of project_dirs(path), sorted
local function names(path)
    jars.scan_cache()
    local out = vim.tbl_map(jars.jar_label, jars.project_dirs(path))
    table.sort(out)
    return out
end

local JVM = h.fixtures .. "/libs/server/src/main/kotlin/libsdemo/Server.kt"
local ANDROID = h.fixtures .. "/libs/app/src/main/kotlin/libsdemo/App.kt"
local COMMON = h.fixtures .. "/libs/kmp/src/commonMain/kotlin/libsdemo/Common.kt"
local DESKTOP = h.fixtures .. "/libs/kmp/src/desktopMain/kotlin/libsdemo/Desktop.kt"
local UNPINNED = h.fixtures .. "/jdk/kmp/src/jvmMain/kotlin/jdkdemo/Jvm.kt"

describe("jar identity", function()
    it("a classifier is not a version: -samples", function()
        assert.are.same({ "ui", "1.11.2", "samples" }, { jars._parse_nv("ui-1.11.2-samples-sources.jar") })
        assert.are.same({ "lifecycle-viewmodel", "2.11.0-beta01" },
            { jars._parse_nv("lifecycle-viewmodel-2.11.0-beta01-sources.jar") })
    end)
    it("the group, from the gradle and the maven layouts", function()
        assert.are.equal("org.jetbrains.kotlin", jars._group_of(
            "/h/.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-stdlib/2.4.0/f00/kotlin-stdlib-2.4.0-sources.jar",
            "kotlin-stdlib", "2.4.0"))
        assert.are.equal("org.jetbrains.kotlin", jars._group_of(
            "/h/.m2/repository/org/jetbrains/kotlin/kotlin-stdlib/2.4.0/kotlin-stdlib-2.4.0-sources.jar",
            "kotlin-stdlib", "2.4.0"))
    end)
    it("platform variants", function()
        assert.are.same({ "ui", "android" }, { jars._variant("ui-android") })
        assert.are.same({ "ui", "desktop" }, { jars._variant("ui-desktop") })
        assert.are.same({ "kotlinx-coroutines-core", "jvm" }, { jars._variant("kotlinx-coroutines-core-jvm") })
        assert.are.same({ "ui", "native" }, { jars._variant("ui-iosarm64") })
        assert.are.same({ "ui", "web" }, { jars._variant("ui-wasm-js") })
        assert.are.same({ "kotlin-stdlib" }, { jars._variant("kotlin-stdlib") })
    end)
end)

describe("version pins", function()
    it("from the version catalog: libraries and the kotlin plugin", function()
        local pins = jars._parse_pins({
            "[versions]",
            'kotlin = "2.4.0"',
            'coroutines = { strictly = "1.9.0" }',
            "",
            "[libraries]",
            'coroutines = { module = "org.jetbrains.kotlinx:kotlinx-coroutines-core", version.ref = "coroutines" }',
            'okio = { group = "com.squareup.okio", name = "okio", version = "3.9.1" }',
            'clikt = "com.github.ajalt.clikt:clikt:5.0.3"',
            "",
            "[plugins]",
            'kotlinJvm = { id = "org.jetbrains.kotlin.jvm", version.ref = "kotlin" }',
        }, {})
        assert.are.equal("1.9.0", pins["org.jetbrains.kotlinx:kotlinx-coroutines-core"])
        assert.are.equal("3.9.1", pins["com.squareup.okio:okio"])
        assert.are.equal("5.0.3", pins["com.github.ajalt.clikt:clikt"])
        assert.are.equal("2.4.0", pins["org.jetbrains.kotlin:*"])
    end)
    it("from build scripts", function()
        local pins = jars._parse_pins({}, {
            'plugins { kotlin("jvm") version "2.0.0" }',
            'dependencies { implementation("io.ktor:ktor-client-core:3.1.0") }',
        })
        assert.are.equal("2.0.0", pins["org.jetbrains.kotlin:*"])
        assert.are.equal("3.1.0", pins["io.ktor:ktor-client-core"])
    end)
end)

describe("jars.project_dirs", function()
    before_each(setup)
    after_each(teardown)

    it("several versions of a library: the newest", function()
        lib("org.jetbrains.kotlin", "kotlin-stdlib-2.0.0-sources.jar")
        lib("org.jetbrains.kotlin", "kotlin-stdlib-2.4.10-sources.jar")
        lib("org.jetbrains.kotlin", "kotlin-stdlib-2.4.0-sources.jar")
        assert.are.same({ "kotlin-stdlib-2.4.10-sources.jar" }, names(UNPINNED))
    end)
    it("the version the project pins, when extracted", function()
        lib("org.jetbrains.kotlin", "kotlin-stdlib-2.4.10-sources.jar")
        lib("org.jetbrains.kotlin", "kotlin-stdlib-2.0.0-sources.jar")
        lib("org.jetbrains.kotlinx", "kotlinx-coroutines-core-1.11.0-sources.jar")
        lib("org.jetbrains.kotlinx", "kotlinx-coroutines-core-1.9.0-sources.jar")
        -- libs/gradle/libs.versions.toml: kotlin 2.0.0, coroutines 1.9.0
        assert.are.same({ "kotlin-stdlib-2.0.0-sources.jar", "kotlinx-coroutines-core-1.9.0-sources.jar" }, names(JVM))
    end)
    it("one artifact name of two libraries: both", function()
        lib("androidx.core", "core-1.18.0-sources.jar")
        lib("com.google.zxing", "core-3.5.0-sources.jar")
        assert.are.same({ "core-1.18.0-sources.jar", "core-3.5.0-sources.jar" }, names(JVM))
    end)
    it("samples are no version of the library", function()
        lib("androidx.compose.ui", "ui-1.11.2-sources.jar")
        lib("androidx.compose.ui", "ui-1.11.2-samples-sources.jar")
        assert.are.same({ "ui-1.11.2-samples-sources.jar", "ui-1.11.2-sources.jar" }, names(JVM))
    end)
    it("platform variants by the file's platform", function()
        lib("androidx.compose.ui", "ui-1.11.2-sources.jar")
        lib("androidx.compose.ui", "ui-android-1.11.2-sources.jar")
        lib("org.jetbrains.compose.ui", "ui-desktop-1.11.1-sources.jar")
        lib("org.jetbrains.kotlinx", "kotlinx-coroutines-core-1.11.0-sources.jar")
        lib("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm-1.11.0-sources.jar")
        assert.are.same({
            "kotlinx-coroutines-core-1.11.0-sources.jar", "kotlinx-coroutines-core-jvm-1.11.0-sources.jar",
            "ui-1.11.2-sources.jar", "ui-android-1.11.2-sources.jar",
        }, names(ANDROID))
        assert.are.same({
            "kotlinx-coroutines-core-1.11.0-sources.jar", "kotlinx-coroutines-core-jvm-1.11.0-sources.jar",
            "ui-1.11.2-sources.jar", "ui-desktop-1.11.1-sources.jar",
        }, names(DESKTOP))
        -- common code: the common artifact, no variant of it
        assert.are.same({ "kotlinx-coroutines-core-1.11.0-sources.jar", "ui-1.11.2-sources.jar" }, names(COMMON))
    end)
    it("a variant without its common artifact stays for common code", function()
        lib("com.materialkolor", "material-kolor-android-sources.jar")
        assert.are.same({ "material-kolor-android-sources.jar" }, names(COMMON))
    end)
    it("the jar gone from the caches: the library told by the root package of its sources", function()
        -- source files in packages `pkgs`
        local function orphan(base, ...)
            local files = {}
            for n, pkg in ipairs({ ... }) do files["commonMain/F" .. n .. ".kt"] = { "package " .. pkg, "", "class F" } end
            vim.fn.writefile({}, lib("x", base, files) .. "/.jarpath")
        end
        orphan("kotlin-stdlib-2.4.0-sources.jar", "kotlin.collections", "kotlin.text", "kotlin")
        orphan("kotlin-stdlib-2.4.10-sources.jar", "kotlin", "kotlin.io")
        orphan("core-1.18.0-sources.jar", "androidx.core.app", "androidx.core.content")
        orphan("core-3.5.0-sources.jar", "com.google.zxing.common", "com.google.zxing")
        assert.are.same({ "core-1.18.0-sources.jar", "core-3.5.0-sources.jar", "kotlin-stdlib-2.4.10-sources.jar" },
            names(UNPINNED))
        -- pinned by the artifact name
        orphan("kotlin-stdlib-2.0.0-sources.jar", "kotlin")
        orphan("kotlinx-coroutines-core-1.9.0-sources.jar", "kotlinx.coroutines", "kotlinx.coroutines.flow")
        orphan("kotlinx-coroutines-core-1.11.0-sources.jar", "kotlinx.coroutines.flow", "kotlinx.coroutines")
        assert.are.same({ "core-1.18.0-sources.jar", "core-3.5.0-sources.jar", "kotlin-stdlib-2.0.0-sources.jar",
            "kotlinx-coroutines-core-1.9.0-sources.jar" }, names(JVM))
    end)
    it("no sources (a -ktx shell): merged by the group", function()
        lib("androidx.activity", "activity-ktx-1.10.1-sources.jar", false)
        lib("androidx.activity", "activity-ktx-1.13.0-sources.jar", false)
        assert.are.same({ "activity-ktx-1.13.0-sources.jar" }, names(JVM))
    end)
    it("no sources, no group: never merged", function()
        vim.fn.writefile({}, lib("androidx.activity", "activity-ktx-1.10.1-sources.jar", false) .. "/.jarpath")
        vim.fn.writefile({}, lib("androidx.activity", "activity-ktx-1.13.0-sources.jar", false) .. "/.jarpath")
        assert.are.same({ "activity-ktx-1.10.1-sources.jar", "activity-ktx-1.13.0-sources.jar" }, names(JVM))
    end)
end)

describe("jars.backfill", function()
    before_each(setup)
    after_each(teardown)

    it("finds where an extracted jar came from: its group", function()
        local gradle = tmp .. "/gradle"
        local jar = gradle .. "/androidx.core/core/1.18.0/0abc/core-1.18.0-sources.jar"
        vim.fn.mkdir(vim.fs.dirname(jar), "p")
        vim.fn.writefile({}, jar)
        local dir = tmp .. "/cache/" .. vim.fn.sha256(jar)
        vim.fn.mkdir(dir, "p")
        vim.fn.writefile({ "core-1.18.0-sources.jar" }, dir .. "/.jarname")
        vim.fn.writefile({}, dir .. "/.extracted")
        config.setup({ cache_dir = tmp .. "/cache", jar_search_roots = { gradle } })
        local done = false
        jars.backfill(function() done = true end)
        assert.is_true(h.wait(function() return done end))
        assert.are.same({ jar }, vim.fn.readfile(dir .. "/.jarpath"))
        jars.scan_cache()
        assert.are.equal("androidx.core", jars.info(dir).group)
    end)
end)

describe("defs.latest_only", function()
    before_each(setup)
    after_each(teardown)

    local function hit(dir, rel, lnum) return { filename = dir .. "/" .. rel, lnum = lnum or 1, text = "class X" } end

    it("the newest version of a library, per library", function()
        local old = lib("androidx.core", "core-1.16.0-sources.jar")
        local new = lib("androidx.core", "core-1.18.0-sources.jar")
        local other = lib("com.google.zxing", "core-3.5.0-sources.jar")
        jars.scan_cache()
        local kept = defs.latest_only({ hit(old, "a/X.kt"), hit(new, "a/X.kt"), hit(other, "z/X.kt") })
        assert.are.same({ new .. "/a/X.kt", other .. "/z/X.kt" }, vim.tbl_map(function(it) return it.filename end, kept))
    end)
    it("a file of several artifacts: from the shortest name, every hit of it", function()
        local core = lib("org.jetbrains.kotlinx", "kotlinx-coroutines-core-1.11.0-sources.jar")
        local jvm = lib("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm-1.11.0-sources.jar")
        jars.scan_cache()
        local kept = defs.latest_only({
            hit(jvm, "commonMain/flow/Flow.kt", 3), hit(core, "commonMain/flow/Flow.kt", 3),
            hit(core, "commonMain/flow/Flow.kt", 9), hit(jvm, "jvmMain/flow/FlowJvm.kt", 2),
        })
        assert.are.same({
            core .. "/commonMain/flow/Flow.kt:3", core .. "/commonMain/flow/Flow.kt:9", jvm .. "/jvmMain/flow/FlowJvm.kt:2",
        }, vim.tbl_map(function(it) return it.filename .. ":" .. it.lnum end, kept))
    end)
end)

describe("gd with several versions extracted", function()
    before_each(setup)
    after_each(teardown)

    local function gd(file, needle, word)
        local sel = h.capture_select()
        h.open(file)
        h.cursor_at(needle, word)
        local buf, pos = h.bufname(), vim.api.nvim_win_get_cursor(0)[1]
        actions.goto_definition()
        h.wait(function() return h.bufname() ~= buf or h.cur_line() ~= pos or sel.list ~= nil end)
        assert.is_nil(sel.list and h.format_rows(sel), "picker opened instead of a jump")
    end

    it("the pinned version, no picker", function()
        local src = { ["commonMain/kotlinx/coroutines/flow/Flow.kt"] = {
            "package kotlinx.coroutines.flow", "", "public interface Flow<out T>" } }
        lib("org.jetbrains.kotlinx", "kotlinx-coroutines-core-1.11.0-sources.jar", src)
        local pinned = lib("org.jetbrains.kotlinx", "kotlinx-coroutines-core-1.9.0-sources.jar", src)
        lib("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm-1.9.0-sources.jar", src)
        jars.scan_cache()
        gd("libs/server/src/main/kotlin/libsdemo/Server.kt", "fun libsFlow()", "Flow<")
        assert.are.equal(pinned .. "/commonMain/kotlinx/coroutines/flow/Flow.kt", h.bufname())
    end)    it("a companion member of a class whose constructor has a line of its own", function()
        local dir = lib("org.jetbrains.kotlin", "kotlin-stdlib-2.0.0-sources.jar", {
            ["commonMain/kotlin/time/Duration.kt"] = {
                "package kotlin.time", "",
                "public value class Duration",
                "internal constructor(private val rawValue: Long) :",
                "    Comparable<Duration> {",
                "    public companion object {",
                "        public val ZERO: Duration = Duration(0L)",
                "    }",
                "}",
            } })
        jars.scan_cache()
        gd("libs/server/src/main/kotlin/libsdemo/Server.kt", "import kotlin.time.Duration.Companion.ZERO", "ZERO")
        assert.are.equal(dir .. "/commonMain/kotlin/time/Duration.kt", h.bufname())
        assert.are.equal(7, h.cur_line())
        gd("libs/server/src/main/kotlin/libsdemo/Server.kt", "fun libsZero()", "ZERO")
        assert.are.equal(7, h.cur_line())
    end)
    describe("an extension imported from an object (3.days)", function()
        local dir
        before_each(function()
            dir = lib("org.jetbrains.kotlin", "kotlin-stdlib-2.0.0-sources.jar", {
                ["commonMain/kotlin/time/Duration.kt"] = {
                    "package kotlin.time", "",
                    "public value class Duration(private val rawValue: Long) {",
                    "    public companion object {",
                    "        public inline val Int.days: Duration get() = TODO()",
                    "        public inline val Long.days: Duration get() = TODO()",
                    "        public inline val Double.days: Duration get() = TODO()",
                    "    }",
                    "}",
                } })
            -- an unrelated member of the name
            lib("org.jetbrains.kotlinx", "kotlinx-datetime-0.7.0-sources.jar", {
                ["commonMain/kotlinx/datetime/YearMonth.kt"] = {
                    "package kotlinx.datetime", "", "public class YearMonth {", "    public val days: Int = 0", "}",
                } })
            jars.scan_cache()
        end)
        local SERVER = "libs/server/src/main/kotlin/libsdemo/Server.kt"

        it("on an Int literal: the Int one", function()
            gd(SERVER, "fun libsDaysInt()", "days")
            assert.are.equal(dir .. "/commonMain/kotlin/time/Duration.kt", h.bufname())
            assert.are.equal(5, h.cur_line())
        end)
        it("on a Long / Double literal: that one", function()
            gd(SERVER, "fun libsDaysLong()", "days")
            assert.are.equal(6, h.cur_line())
            gd(SERVER, "fun libsDaysDouble()", "days")
            assert.are.equal(7, h.cur_line())
        end)
        it("a typed receiver: the one of its type", function()
            gd(SERVER, "fun libsDaysOf(", "days")
            assert.are.equal(dir .. "/commonMain/kotlin/time/Duration.kt", h.bufname())
            assert.are.equal(5, h.cur_line())
        end)
        it("a member of the receiver's type wins", function()
            gd(SERVER, "fun libsSpan(", "days")
            assert.are.equal("libs/server/src/main/kotlin/libsdemo/Server.kt", h.relname())
            assert.is_truthy(vim.api.nvim_get_current_line():find("class Span", 1, true))
        end)
    end)
    it("a member of a java interface with its brace on a line of its own", function()
        local dir = lib("com.example", "pathy-1.0-sources.jar", {
            ["com/example/pathy/Pathy.java"] = {
                "package com.example.pathy;", "",
                "public interface Pathy",
                "    extends Comparable<Pathy>",
                "{",
                "    default String asText() {",
                "        return null;",
                "    }",
                "}",
            } })
        jars.scan_cache()
        gd("libs/server/src/main/kotlin/libsdemo/Server.kt", "fun libsPathy(", "asText")
        assert.are.equal(dir .. "/com/example/pathy/Pathy.java", h.bufname())
        assert.are.equal(6, h.cur_line())
    end)
    it("the jvm actual in a source set not named *Main (jvmJUnit5)", function()
        lib("org.jetbrains.kotlin", "kotlin-test-2.4.20-sources.jar", { ["annotationsCommonMain/kotlin.test/Annotations.kt"] = {
            "package kotlin.test", "", "public expect annotation class Test()" } })
        local junit5 = lib("org.jetbrains.kotlin", "kotlin-test-junit5-2.4.20-sources.jar", {
            ["annotationsCommonMain/kotlin.test/Annotations.kt"] = {
                "package kotlin.test", "", "public expect annotation class Test()" },
            ["jvmJUnit5/Annotations.kt"] = {
                "package kotlin.test", "", "public actual typealias Test = org.junit.jupiter.api.Test" } })
        jars.scan_cache()
        gd("libs/server/src/main/kotlin/libsdemo/Server.kt", "@Test fun libsCase", "Test")
        assert.are.equal(junit5 .. "/jvmJUnit5/Annotations.kt", h.bufname())
    end)
end)
