-- libs.x.y and projects.x: the version catalog entry, the module.

local h = require("helpers")
local actions = require("kotlin-lite.actions")
local resolve = require("kotlin-lite.resolve")

local BUILD = "gradlegen/app/build.gradle.kts"
local TOML = "gradlegen/gradle/libs.versions.toml"

-- cursor on `name` inside `needle` in the app's build file
local function cursor(needle, name, file)
    h.open(file or BUILD)
    local lnum = h.line_of(needle)
    vim.api.nvim_win_set_cursor(0, { lnum, vim.fn.getline(lnum):find(needle, 1, true) + needle:find(name, 1, true) - 2 })
end

local function at(needle, name)
    cursor(needle, name)
    local cur = vim.api.nvim_win_get_cursor(0)
    local res = resolve.run_sync(resolve.context_at(resolve.base(0), cur[1], cur[2]))
    return res.jump and (vim.fn.fnamemodify(res.jump.filename, ":.") .. ":" .. res.jump.lnum) or res.err
end

describe("version catalog", function()
    after_each(h.reset)

    local cases = {
        { "plugin", "libs.plugins.kotlin.jvm", "jvm", TOML .. ":13" },
        { "from a middle segment", "libs.plugins.kotlin.jvm", "kotlin", TOML .. ":13" },
        { "library, by its own section", "libs.kotlin.jvm", "jvm", TOML .. ":7" },
        { "library with dashes", "libs.androidx.core.ktx", "core", TOML .. ":6" },
        { "bundle", "libs.bundles.ui", "ui", TOML .. ":10" },
        { "version, before .get()", "libs.versions.kotlin", "kotlin", TOML .. ":2" },
        { "project accessor: the module's build file", "projects.coreUi", "coreUi", "gradlegen/core-ui/build.gradle.kts:1" },
    }
    for _, c in ipairs(cases) do
        local name, needle, word, want = unpack(c)
        it(name, function()
            assert.are.equal(want, at(needle, word))
        end)
    end

    it("K: the entry and its version", function()
        local shown
        h.stub(vim.lsp.util, "open_floating_preview", function(lines) shown = lines end)
        cursor("libs.plugins.kotlin.jvm", "jvm")
        actions.hover()
        h.wait(function() return shown ~= nil end)
        assert.are.same({
            "libs.plugins.kotlin.jvm",
            "",
            '[plugins]   kotlin-jvm = { id = "org.jetbrains.kotlin.jvm", version.ref = "kotlin" }',
            '[versions]  kotlin = "2.1.0"',
        }, shown)
    end)

    local function usages(needle, name)
        cursor(needle, name)
        actions.find_usages()
        h.wait(function() return #vim.fn.getqflist() > 0 end)
        local out = vim.tbl_map(function(it)
            return vim.fn.fnamemodify(vim.fn.bufname(it.bufnr), ":.") .. ":" .. it.lnum .. ":" .. it.col
        end, vim.fn.getqflist())
        table.sort(out)
        return out
    end

    it("gu: the accessor in every build file", function()
        assert.are.same({ BUILD .. ":2:31", "gradlegen/core-ui/build.gradle.kts:2:31" },
            usages("libs.plugins.kotlin.jvm", "jvm"))
    end)

    it("gu: a project accessor", function()
        assert.are.same({ BUILD .. ":24:29" }, usages("projects.coreUi", "coreUi"))
    end)
end)
