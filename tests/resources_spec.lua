-- R.<type>.<name> / Res.<type>.<name>: Android and Compose resources.

local h = require("helpers")
local actions = require("kotlin-lite.actions")
local resolve = require("kotlin-lite.resolve")

local USE = "resources/app/src/main/java/com/example/res/UseRes.kt"
local RES = "resources/app/src/main/res/"
local COMPOSE = "resources/shared/src/commonMain/composeResources/"

-- cursor on `name` inside `needle` (R.string.x) of UseRes.kt
local function cursor(needle, name)
    h.open(USE)
    local lnum = h.line_of(needle)
    local s = vim.fn.getline(lnum):find(needle, 1, true)
    vim.api.nvim_win_set_cursor(0, { lnum, s - 1 + needle:find(name, 1, true) - 1 })
end

local function at(needle, name)
    cursor(needle, name)
    local cur = vim.api.nvim_win_get_cursor(0)
    return resolve.run_sync(resolve.context_at(resolve.base(0), cur[1], cur[2]))
end

local function rel(it)
    return vim.fn.fnamemodify(it.filename, ":.") .. ":" .. it.lnum
end

describe("resources", function()
    after_each(h.reset)

    local cases = {
        { "string: the default values/", "R.string.greeting", "greeting", RES .. "values/strings.xml:3" },
        { "fully qualified R", "R.string.app_name", "app_name", RES .. "values/strings.xml:2" },
        { "plurals", "R.plurals.apples", "apples", RES .. "values/strings.xml:4" },
        { "array: string-array", "R.array.planets", "planets", RES .. "values/strings.xml:8" },
        { "style: `_` for `.`", "R.style.Theme_Fixture", "Theme_Fixture", RES .. "values/strings.xml:11" },
        { "color: not a style item", "R.color.accent", "accent", RES .. "values/colors.xml:2" },
        { "drawable: the unqualified dir", "R.drawable.ic_star", "ic_star", RES .. "drawable/ic_star.xml:1" },
        { "mipmap: any file type", "R.mipmap.ic_launcher", "ic_launcher", RES .. "mipmap-hdpi/ic_launcher.png:1" },
        { "layout", "R.layout.screen_main", "screen_main", RES .. "layout/screen_main.xml:1" },
        { "id: where it is created", "R.id.title", "title", RES .. "layout/screen_main.xml:3" },
        { "compose string", "Res.string.maracas", "maracas", COMPOSE .. "values/strings.xml:2" },
        { "compose drawable", "Res.drawable.logo", "logo", COMPOSE .. "drawable/logo.xml:1" },
    }
    for _, c in ipairs(cases) do
        local name, needle, word, want = unpack(c)
        it(name, function()
            local res = at(needle, word)
            assert.is_nil(res.err)
            assert.is_not_nil(res.jump, "no jump")
            assert.are.equal(want, rel(res.jump))
        end)
    end

    it("keeps the qualified ones for K", function()
        local res = at("R.string.greeting", "greeting")
        assert.are.same({ RES .. "values/strings.xml:3", RES .. "values-uk/strings.xml:2" },
            vim.tbl_map(rel, res.resources))
    end)

    it("unknown resource: not found", function()
        assert.is_not_nil(at("R.string.absent", "absent").err)
    end)

    it("android.R is not the project's", function()
        local res = at("android.R.string.ok", "ok")
        assert.is_nil(res.resources)
        assert.is_not_nil(res.err)
    end)

    it("only the name: `string` in R.string.x is not a resource", function()
        assert.is_nil(at("R.string.greeting", "string").resources)
    end)

    it("gd jumps into the xml", function()
        cursor("R.string.greeting", "greeting")
        actions.goto_definition()
        assert.is_true(h.wait_jump())
        assert.are.equal(RES .. "values/strings.xml", h.relname())
        assert.are.equal(3, h.cur_line())
    end)

    it("gri: a resource has no implementations", function()
        local note = h.capture_notify()
        cursor("R.string.greeting", "greeting")
        actions.goto_implementation()
        h.wait(function() return note.msg ~= nil end)
        assert.are.equal("kotlin-lite: R.string.greeting is a resource", note.msg)
    end)

    it("K lists the value per qualifier", function()
        local shown
        h.stub(vim.lsp.util, "open_floating_preview", function(lines) shown = lines end)
        cursor("R.string.greeting", "greeting")
        actions.hover()
        h.wait(function() return shown ~= nil end)
        assert.are.same({
            "R.string.greeting",
            "",
            "values     Hello",
            "values-uk  Привіт",
        }, shown)
    end)

    it("K on a file resource lists the files", function()
        local shown
        h.stub(vim.lsp.util, "open_floating_preview", function(lines) shown = lines end)
        cursor("R.drawable.ic_star", "ic_star")
        actions.hover()
        h.wait(function() return shown ~= nil end)
        assert.are.same({
            "R.drawable.ic_star",
            "",
            "drawable        " .. RES .. "drawable/ic_star.xml",
            "drawable-night  " .. RES .. "drawable-night/ic_star.xml",
        }, shown)
    end)
end)
