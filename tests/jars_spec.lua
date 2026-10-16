local jars = require("kotlin-lite.jars")

describe("jars", function()
    describe("parse_nv", function()
        it("artifact with a suffix", function()
            assert.are.same({ "kotlin-stdlib-jdk8", "2.2.10" },
                { jars._parse_nv("kotlin-stdlib-jdk8-2.2.10-sources.jar") })
        end)
        it("plain artifact", function()
            assert.are.same({ "kotlin-stdlib", "2.4.0" }, { jars._parse_nv("kotlin-stdlib-2.4.0-sources.jar") })
        end)
    end)

    describe("ver_lt", function()
        it("compares numerically (2.2.0 < 2.10.0)", function()
            assert.is_true(jars._ver_lt("2.2.0", "2.10.0"))
        end)
        it("equal versions are not <", function()
            assert.is_false(jars._ver_lt("2.4.0", "2.4.0"))
        end)
        it("pre-release < release", function()
            assert.is_true(jars._ver_lt("2.4.0-RC", "2.4.0"))
        end)
    end)

    it("latest_by_artifact collapses each artifact to its newest version", function()
        local picked = {}
        for _, e in ipairs(jars._latest_by_artifact({
            "/c/kotlin-stdlib-2.0.0-sources.jar",
            "/c/kotlin-stdlib-2.2.0-sources.jar",
            "/c/kotlin-stdlib-2.4.0-sources.jar",
            "/c/kotlin-stdlib-jdk8-1.9.24-sources.jar",
        })) do
            picked[e.artifact] = e.version
        end
        assert.are.same({ ["kotlin-stdlib"] = "2.4.0", ["kotlin-stdlib-jdk8"] = "1.9.24" }, picked)
    end)
end)

describe("auto-extract essentials", function()
    local e = require("kotlin-lite.config").options.essentials

    it("kotlin has the stdlib", function()
        assert.is_true(vim.tbl_contains(e.kotlin, "kotlin-stdlib"))
    end)
    it("test has junit + kotlin-test", function()
        assert.is_true(vim.tbl_contains(e.test, "junit"))
        assert.is_true(vim.tbl_contains(e.test, "kotlin-test"))
    end)
    it("compose has material3 + ui", function()
        assert.is_true(vim.tbl_contains(e.compose, "material3"))
        assert.is_true(vim.tbl_contains(e.compose, "ui"))
    end)
end)

describe("is_android_project", function()
    local h = require("helpers")

    it("android plugin via a version-catalog alias in a module build script", function()
        assert.is_true(jars.is_android_project(h.fixtures .. "/android"))
    end)
    it("a module with src/main/AndroidManifest.xml", function()
        assert.is_true(jars.is_android_project(h.fixtures .. "/android-manifest"))
    end)
    it("plain gradle / KMP projects are not", function()
        assert.is_false(jars.is_android_project(h.fixtures .. "/runner/gradle"))
        assert.is_false(jars.is_android_project(h.fixtures .. "/runner/kmp"))
    end)
    it("no root -> false (no tree walk from the cwd)", function()
        assert.is_false(jars.is_android_project(nil))
    end)
end)

describe("auto_extract", function()
    local h = require("helpers")
    local config = require("kotlin-lite.config")
    local tmp

    before_each(function()
        tmp = vim.fn.tempname()
        -- no search roots: the jar search itself is a no-op
        config.setup({ auto_extract = true, cache_dir = tmp, jar_search_roots = {} })
    end)
    after_each(function()
        h.reset()
        vim.fn.delete(tmp, "rf")
    end)

    it("stamps the cache scan per project kind", function()
        jars.auto_extract(h.fixtures .. "/runner/gradle")
        jars.auto_extract(h.fixtures .. "/android")
        assert.are.equal(1, vim.fn.filereadable(tmp .. "/.auto_extract.jvm"))
        assert.are.equal(1, vim.fn.filereadable(tmp .. "/.auto_extract.android"))
    end)

    it("skips the scan while the stamp is fresh, rescans once it is stale", function()
        local stamp = tmp .. "/.auto_extract.jvm"
        local function age() return os.time() - vim.uv.fs_stat(stamp).mtime.sec end
        local function set_age(sec) vim.uv.fs_utime(stamp, os.time() - sec, os.time() - sec) end

        jars.auto_extract(nil)
        set_age(60 * 60)
        jars.auto_extract(nil) -- fresh -> skipped, stamp untouched
        assert.is_true(age() >= 60 * 60 - 5)

        set_age(25 * 60 * 60)
        jars.auto_extract(nil) -- stale -> rescans, refreshes the stamp
        assert.is_true(age() < 60)
    end)

    it("does nothing when disabled", function()
        config.setup({ auto_extract = false, cache_dir = tmp })
        jars.auto_extract(nil)
        assert.are.equal(0, vim.fn.isdirectory(tmp))
    end)
end)
