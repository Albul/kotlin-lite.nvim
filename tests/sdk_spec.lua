-- Android SDK sources for android code: sources/android-<compileSdk>, else the
-- nearest installed, then the platform's android-stubs-src.jar for the rest.

local h = require("helpers")
local sdk = require("kotlin-lite.sdk")
local config = require("kotlin-lite.config")
local actions = require("kotlin-lite.actions")

local tests_dir = vim.fn.fnamemodify(h.fixtures, ":h")
local DEMO = "sdk/app/src/main/kotlin/sdkdemo/SdkDemo.kt"

-- a fake SDK in `dir`: sources/android-35 (+ `extra` source levels), platforms
-- 35 (no stubs) and 37.0 (the stubs jar)
local function make_sdk(dir, extra)
    vim.fn.mkdir(dir .. "/sources", "p")
    vim.system({ "cp", "-r", tests_dir .. "/sdk/sources/android-35", dir .. "/sources/" }):wait()
    for _, level in ipairs(extra or {}) do
        vim.system({ "cp", "-r", tests_dir .. "/sdk/sources/android-35", dir .. "/sources/android-" .. level }):wait()
    end
    vim.fn.mkdir(dir .. "/platforms/android-35", "p")
    vim.fn.mkdir(dir .. "/platforms/android-37.0", "p")
    vim.system({ "zip", "-q", "-r", dir .. "/platforms/android-37.0/android-stubs-src.jar", "." },
        { cwd = tests_dir .. "/sdk/stubs/android-37" }):wait()
end

local tmp
local function setup(extra, opts)
    tmp = vim.fn.tempname()
    make_sdk(tmp .. "/sdk", extra)
    config.setup(vim.tbl_extend("force", { android_sdk = tmp .. "/sdk", cache_dir = tmp .. "/cache" }, opts or {}))
    require("kotlin-lite.jars").scan_cache()
    sdk.reset()
end
local function teardown()
    h.reset()
    sdk.reset()
    require("kotlin-lite.jars").scan_cache()
    vim.fn.delete(tmp, "rf")
end

describe("sdk.root", function()
    local saved = {}
    before_each(function()
        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp .. "/a", "p")
        vim.fn.mkdir(tmp .. "/b", "p")
        saved = { vim.env.ANDROID_HOME, vim.env.ANDROID_SDK_ROOT }
        sdk.reset()
    end)
    after_each(function()
        vim.env.ANDROID_HOME, vim.env.ANDROID_SDK_ROOT = saved[1], saved[2]
        h.reset()
        sdk.reset()
        vim.fn.delete(tmp, "rf")
    end)

    it("the android_sdk option first", function()
        vim.env.ANDROID_HOME = tmp .. "/b"
        config.setup({ android_sdk = tmp .. "/a" })
        assert.are.equal(tmp .. "/a", sdk.root(h.fixtures .. "/sdk"))
    end)
    it("then $ANDROID_HOME, then $ANDROID_SDK_ROOT", function()
        vim.env.ANDROID_HOME, vim.env.ANDROID_SDK_ROOT = tmp .. "/a", tmp .. "/b"
        assert.are.equal(tmp .. "/a", sdk.root(h.fixtures .. "/sdk"))
        vim.env.ANDROID_HOME = nil
        sdk.reset()
        assert.are.equal(tmp .. "/b", sdk.root(h.fixtures .. "/sdk"))
    end)
    it("then sdk.dir of local.properties, when it exists", function()
        vim.env.ANDROID_HOME, vim.env.ANDROID_SDK_ROOT = nil, nil
        local proj = tmp .. "/proj"
        vim.fn.mkdir(proj, "p")
        vim.fn.writefile({ "# Location of the SDK", "sdk.dir=" .. tmp .. "/b" }, proj .. "/local.properties")
        assert.are.equal(tmp .. "/b", sdk.root(proj))
        vim.fn.writefile({ "sdk.dir=" .. tmp .. "/gone" }, proj .. "/local.properties")
        sdk.reset()
        assert.are_not.equal(tmp .. "/gone", sdk.root(proj))
    end)
    it("android_sdk = false: none", function()
        vim.env.ANDROID_HOME = tmp .. "/a"
        config.setup({ android_sdk = false })
        assert.is_nil(sdk.root(h.fixtures .. "/sdk"))
    end)
end)

describe("sdk.compile_sdk", function()
    before_each(function() setup() end)
    after_each(teardown)

    it("through the version catalog (libs.versions.android.compileSdk)", function()
        assert.are.equal(37, sdk.compile_sdk(h.fixtures .. "/" .. DEMO))
    end)
    it("a literal in the module", function()
        assert.are.equal(37, sdk.compile_sdk(h.fixtures .. "/sdk/kmp/src/androidMain/kotlin/sdkdemo/Plat.kt"))
    end)
    it("the forms a build script can take", function()
        assert.are.equal(34, sdk._parse_compile_sdk({ "    compileSdk = 34" }, {}))
        assert.are.equal(33, sdk._parse_compile_sdk({ "    compileSdkVersion(33)" }, {}))
        assert.are.equal(36, sdk._parse_compile_sdk({ "    compileSdk {", "        version = release(36)", "    }" }, {}))
        assert.are.equal(37, sdk._parse_compile_sdk({ "compileSdk = libs.versions.android.compileSdk.get().toInt()" },
            { 'android-compileSdk = "37"' }))
        assert.are.equal(36, sdk._parse_compile_sdk({ "compileSdk = libs.versions.compile.sdk.get().toInt()" },
            { 'compile_sdk = "36"' }))
        assert.is_nil(sdk._parse_compile_sdk({ "android { }" }, {}))
    end)
end)

describe("sdk.is_android", function()
    it("a module with the android plugin", function()
        assert.is_true(sdk.is_android(h.fixtures .. "/" .. DEMO))
    end)
    it("KMP: androidMain yes, commonMain no", function()
        assert.is_true(sdk.is_android(h.fixtures .. "/sdk/kmp/src/androidMain/kotlin/sdkdemo/Plat.kt"))
        assert.is_false(sdk.is_android(h.fixtures .. "/sdk/kmp/src/commonMain/kotlin/sdkdemo/Common.kt"))
    end)
    it("a jvm module no", function()
        assert.is_false(sdk.is_android(h.fixtures .. "/sdk/server/src/main/kotlin/sdkdemo/Server.kt"))
    end)
end)

describe("sdk.dirs", function()
    after_each(teardown)

    it("no sources of compileSdk: the nearest older, then the stubs of compileSdk", function()
        setup()
        local dirs = sdk.dirs(h.fixtures .. "/" .. DEMO)
        assert.are.equal(2, #dirs)
        assert.are.equal(tmp .. "/sdk/sources/android-35", dirs[1])
        assert.is_truthy(dirs[2]:find("android-stubs-37", 1, true))
    end)
    it("the exact sources first", function()
        setup({ 36, "37.0" })
        assert.are.equal(tmp .. "/sdk/sources/android-37.0", sdk.dirs(h.fixtures .. "/" .. DEMO)[1])
    end)
    it("nothing for common code", function()
        setup()
        assert.are.same({}, sdk.dirs(h.fixtures .. "/sdk/kmp/src/commonMain/kotlin/sdkdemo/Common.kt"))
    end)
    it("the stubs are reindented by braces: members inside their class", function()
        setup()
        local stubs = sdk.dirs(h.fixtures .. "/" .. DEMO)[2]
        local lines = vim.fn.readfile(stubs .. "/android/os/Build.java")
        assert.is_true(vim.tbl_contains(lines, "public class Build {"))
        assert.is_true(vim.tbl_contains(lines, "    public static int getMajorSdkVersion(int sdkIntFull) { throw new RuntimeException(\"Stub!\"); }"))
        assert.is_true(vim.tbl_contains(lines, "    public static class VERSION {"))
        assert.is_true(vim.tbl_contains(lines, "        public static final int SDK_INT;"))
        assert.is_true(vim.tbl_contains(lines, "    }"))
        -- braces in a string literal don't count
        local fresh = vim.fn.readfile(stubs .. "/android/os/NewIn37.java")
        assert.is_true(vim.tbl_contains(fresh, "    public int describeContents() { throw new RuntimeException(\"Stub!\"); }"))
    end)
end)

describe("sdk.reindent", function()
    it("depth by braces, outside comments / strings / chars", function()
        assert.are.same({
            "/* { */",
            "class A {",
            "    char c = '{';",
            "    // }",
            "    void f() { }",
            "    static class B {",
            "        int x;",
            "    }",
            "}",
        }, sdk._reindent({
            "/* { */", "class A {", "char c = '{';", "// }", "void f() { }", "static class B {", "int x;", "}", "}",
        }))
    end)
end)

describe("gd into the Android SDK", function()
    local cap

    local function gd(file, needle, word, nth)
        cap = h.capture_notify()
        local sel = h.capture_select()
        h.open(file)
        h.cursor_at(needle, word, nth)
        local buf = h.bufname()
        actions.goto_definition()
        h.wait(function() return h.bufname() ~= buf or sel.list ~= nil or cap.msg ~= nil end)
        assert.is_nil(sel.list and h.format_rows(sel), "picker opened instead of a jump")
    end

    -- now in `rel` (below an SDK dir) on the line with `needle`
    local function assert_in(rel, needle)
        assert.is_truthy(h.bufname():sub(-#rel) == rel, "in " .. h.bufname())
        assert.is_truthy(vim.api.nvim_get_current_line():find(needle, 1, true), vim.api.nvim_get_current_line())
    end
    local function in_sources() return h.bufname():find(tmp .. "/sdk/sources/android-35/", 1, true) == 1 end
    local function in_stubs() return h.bufname():find("android-stubs-37", 1, true) ~= nil end

    before_each(function() setup() end)
    after_each(teardown)

    it("an imported class, on the import line", function()
        gd(DEMO, "import android.os.Build", "Build")
        assert_in("android/os/Build.java", "public class Build {")
        assert.is_true(in_sources())
    end)
    it("an imported class at its use", function()
        gd(DEMO, "fun version()", "Build")
        assert_in("android/os/Build.java", "public class Build {")
        assert.is_true(in_sources())
    end)
    it("a nested class: Build.VERSION", function()
        gd(DEMO, "fun version()", "VERSION")
        assert_in("android/os/Build.java", "public static class VERSION {")
        assert.is_true(in_sources())
    end)
    it("a static field of a nested class: Build.VERSION.SDK_INT", function()
        gd(DEMO, "fun version()", "SDK_INT")
        assert_in("android/os/Build.java", "SDK_INT = SystemProperties")
    end)
    it("Build.VERSION_CODES.Q", function()
        gd(DEMO, "fun code()", "Q")
        assert_in("android/os/Build.java", "int Q = 29")
        assert.is_true(in_sources())
    end)
    it("a static constant: Color.TRANSPARENT", function()
        gd(DEMO, "fun color()", "TRANSPARENT")
        assert_in("android/graphics/Color.java", "TRANSPARENT = 0")
    end)
    it("a member the older sources lack: from the stubs of compileSdk", function()
        gd(DEMO, "fun major()", "getMajorSdkVersion")
        assert_in("android/os/Build.java", "getMajorSdkVersion(int sdkIntFull)")
        assert.is_true(in_stubs())
    end)
    it("a class the older sources lack: from the stubs", function()
        gd(DEMO, "import android.os.NewIn37", "NewIn37")
        assert_in("android/os/NewIn37.java", "public final class NewIn37 {")
        assert.is_true(in_stubs())
    end)
    it("an inherited platform member through a Java getter: packageName", function()
        gd(DEMO, "fun pkg()", "packageName")
        assert_in("android/content/ContextWrapper.java", "public String getPackageName()")
    end)
    it("an inherited Java getter as a property: intent", function()
        gd(DEMO, "fun current()", "intent")
        assert_in("android/app/Activity.java", "public Intent getIntent()")
    end)
    it("a Java getter on a typed receiver: i.action", function()
        gd(DEMO, "fun action(", "action", 2)
        assert_in("android/content/Intent.java", "String getAction()")
    end)
    it("an inherited Java getter beats unrelated members of that name: window", function()
        gd(DEMO, "fun win()", "window")
        assert_in("android/app/Activity.java", "public Window getWindow()")
    end)
    it("not public API (not in the stubs): never a candidate", function()
        gd(DEMO, "fun contrast()", "isNavigationBarContrastEnforced")
        assert_in("android/view/Window.java", "public boolean isNavigationBarContrastEnforced()")
        assert.is_true(in_sources())
    end)
    it("java.lang without an import: Thread", function()
        gd(DEMO, "fun worker()", "Thread")
        assert_in("java/lang/Thread.java", "public class Thread")
    end)
    it("a class of a package the file doesn't import: not jumped to", function()
        gd(DEMO, "fun logger()", "Log")
        assert.is_nil(h.bufname():find("Log.java", 1, true))
    end)
    it("common code doesn't see the SDK", function()
        gd("sdk/kmp/src/commonMain/kotlin/sdkdemo/Common.kt", "fun commonVersion()", "Build")
        assert.are.equal("sdk/kmp/src/commonMain/kotlin/sdkdemo/Common.kt", h.relname())
    end)
    it("androidMain of a KMP module does", function()
        gd("sdk/kmp/src/androidMain/kotlin/sdkdemo/Plat.kt", "fun platVersion()", "SDK_INT")
        assert_in("android/os/Build.java", "SDK_INT")
    end)
    it("a jvm module doesn't: Thread stays unresolved", function()
        gd("sdk/server/src/main/kotlin/sdkdemo/Server.kt", "fun serverWorker()", "Thread")
        assert.are.equal("sdk/server/src/main/kotlin/sdkdemo/Server.kt", h.relname())
    end)
    it("older sources than compileSdk: said once per session", function()
        gd(DEMO, "fun version()", "Build")
        assert.is_true(h.wait(function() return cap.msg ~= nil end))
        assert.is_truthy(cap.msg:find("API 35", 1, true))
        assert.is_truthy(cap.msg:find("compileSdk 37", 1, true))
        assert.is_truthy(cap.msg:find('sdkmanager "sources;android-37"', 1, true))
        gd(DEMO, "fun color()", "Color")
        assert.is_nil(cap.msg)
    end)
    it("jar sources stay read-only: the SDK too", function()
        gd(DEMO, "fun version()", "Build")
        assert.is_false(vim.bo.modifiable)
    end)
end)

describe("gd into the exact SDK sources", function()
    before_each(function() setup({ "37.0" }) end)
    after_each(teardown)

    it("no note", function()
        local cap = h.capture_notify()
        h.open(DEMO)
        h.cursor_at("fun version()", "Build")
        local buf = h.bufname()
        actions.goto_definition()
        assert.is_true(h.wait(function() return h.bufname() ~= buf end))
        assert.is_truthy(h.bufname():find("/sources/android-37.0/", 1, true))
        assert.is_nil(cap.msg)
    end)
end)
