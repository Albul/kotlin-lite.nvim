-- BuildConfig.X: the buildConfigField (or android property) that generates it.

local h = require("helpers")
local actions = require("kotlin-lite.actions")
local resolve = require("kotlin-lite.resolve")

local USE = "gradlegen/app/src/main/kotlin/gen/UseGenerated.kt"
local BUILD = "gradlegen/app/build.gradle.kts"

local function cursor(needle, name)
    h.open(USE)
    local lnum = h.line_of(needle)
    vim.api.nvim_win_set_cursor(0, { lnum, vim.fn.getline(lnum):find(needle, 1, true) + #needle - #name - 1 })
end

local function at(needle, name)
    cursor(needle, name)
    local cur = vim.api.nvim_win_get_cursor(0)
    return resolve.run_sync(resolve.context_at(resolve.base(0), cur[1], cur[2]))
end

local function rel(it)
    return vim.fn.fnamemodify(it.filename, ":.") .. ":" .. it.lnum
end

describe("BuildConfig", function()
    after_each(h.reset)

    it("a buildConfigField", function()
        assert.are.equal(BUILD .. ":8", rel(at("BuildConfig.LOGS", "LOGS").jump))
    end)

    it("one per build type: a choice", function()
        assert.are.same({ BUILD .. ":12", BUILD .. ":15" }, vim.tbl_map(rel, at("BuildConfig.API_URL", "API_URL").pool))
    end)

    it("built in: the android property", function()
        assert.are.equal(BUILD .. ":7", rel(at("BuildConfig.VERSION_NAME", "VERSION_NAME").jump))
    end)

    it("unknown field: not found", function()
        assert.is_not_nil(at("BuildConfig.ABSENT", "ABSENT").err)
    end)

    it("gd jumps into the build file", function()
        cursor("BuildConfig.LOGS", "LOGS")
        actions.goto_definition()
        assert.is_true(h.wait_jump())
        assert.are.equal(BUILD, h.relname())
        assert.are.equal(8, h.cur_line())
    end)

    it("K lists the field per build type", function()
        local shown
        h.stub(vim.lsp.util, "open_floating_preview", function(lines) shown = lines end)
        cursor("BuildConfig.API_URL", "API_URL")
        actions.hover()
        h.wait(function() return shown ~= nil end)
        assert.are.same({
            "BuildConfig.API_URL",
            "",
            'debug    buildConfigField("String", "API_URL", "\\"https://dev.example.com\\"")',
            'release  buildConfigField("String", "API_URL", "\\"https://example.com\\"")',
        }, shown)
    end)

    it("gu: its uses", function()
        cursor("BuildConfig.LOGS", "LOGS")
        actions.find_usages()
        h.wait(function() return #vim.fn.getqflist() > 0 end)
        assert.are.same({ { lnum = 4, col = 25 } }, vim.tbl_map(function(item)
            return { lnum = item.lnum, col = item.col }
        end, vim.fn.getqflist()))
    end)
end)
