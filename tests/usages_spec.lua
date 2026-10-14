local h = require("helpers")
local actions = require("kotlin-lite.actions")
local search = require("kotlin-lite.search")

describe("gu / gr (find usages)", function()
    after_each(h.reset)

    local function usages(file, needle, word)
        h.open(file)
        h.cursor_at(needle, word)
        actions.find_usages()
        h.wait(function() return #vim.fn.getqflist() > 0 end)
        return vim.fn.getqflist()
    end

    it("fills the quickfix list across files", function()
        local qf = usages("Main.kt", "area(3.0", "area")
        local files = {}
        for _, it in ipairs(qf) do
            files[vim.fn.fnamemodify(vim.api.nvim_buf_get_name(it.bufnr), ":t")] = true
        end
        assert.are.equal(4, #qf)
        assert.are.same({ ["Geometry.kt"] = true, ["Main.kt"] = true }, files)
    end)

    it("skips comment / KDoc mentions", function()
        local qf = usages("Geometry.kt", "class Circle", "radius")
        assert.is_true(#qf > 0)
        for _, it in ipairs(qf) do
            assert.falsy(it.text:find("[radius]", 1, true))
        end
    end)
end)

describe("search.is_comment_text", function()
    it("detects KDoc and block comments", function()
        assert.is_true(search.is_comment_text("  * [radius]"))
        assert.is_true(search.is_comment_text("/* x */"))
    end)

    it("ignores code with a trailing comment", function()
        assert.is_false(search.is_comment_text("val a = b // c"))
    end)
end)
