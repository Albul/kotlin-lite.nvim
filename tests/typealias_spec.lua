-- typealias: grt, member lookup and gri see through it to the aliased type.

local h = require("helpers")
local actions = require("kotlin-lite.actions")

local FILE = "alias/Alias.kt"

-- run `action` on `word` of the line with `needle` -> the picker's lines, or the
-- line the cursor ends on
local function run(action, needle, word)
    local cap = h.capture_select()
    h.open(FILE)
    h.cursor_at(needle, word)
    local start = vim.api.nvim_win_get_cursor(0)
    action()
    h.wait(function() return cap.list ~= nil or not vim.deep_equal(vim.api.nvim_win_get_cursor(0), start) end)
    if cap.list then
        local lines = vim.tbl_map(function(r) return r.data.lnum end, cap.list)
        table.sort(lines)
        return lines
    end
    return h.cur_line()
end

describe("typealias", function()
    after_each(h.reset)

    it("grt: the aliased type", function()
        assert.are.equal(3, run(actions.goto_type_definition, "heart.beat()", "heart"))
    end)

    it("grt: a function type alias stays at the alias", function()
        assert.are.equal(21, run(actions.goto_type_definition, "val onBeat: OnBeat", "onBeat"))
    end)

    it("gd: a member through the alias", function()
        assert.are.equal(4, run(actions.goto_definition, "heart.beat()", "beat"))
    end)

    it("gd on the alias: the alias", function()
        assert.are.equal(19, run(actions.goto_definition, "val heart: Heart", "Heart"))
    end)

    it("gri on the type: subtypes through the alias too", function()
        assert.are.same({ 7, 11 }, run(actions.goto_implementation, "interface Pump", "Pump"))
    end)

    it("gri on the alias: the aliased type's subtypes", function()
        assert.are.same({ 7, 11 }, run(actions.goto_implementation, "val heart: Heart", "Heart"))
    end)
end)
