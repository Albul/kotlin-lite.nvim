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
