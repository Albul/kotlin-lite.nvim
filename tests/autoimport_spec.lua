local h = require("helpers")
local actions = require("kotlin-lite.actions")
local autoimport = require("kotlin-lite.autoimport")

describe("auto-import", function()
    local note, picked

    before_each(function()
        note, picked = nil, nil
        h.stub(vim, "notify", function(msg) note = msg end)
        h.stub(vim.ui, "select", function(list)
            picked = vim.tbl_map(function(c) return c.fq end, list)
        end)
    end)
    after_each(h.reset)

    -- run auto-import on `word` in the first line containing `needle`;
    -- -> the added import line, or nil (then see `note` / `picked`)
    local function run(file, needle, word)
        h.open(file)
        h.cursor_at(needle, word)
        actions.auto_import_under_cursor()
        h.wait(function() return note ~= nil or picked ~= nil end)
        for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, 10, false)) do
            if l:match("^import ") then return l end
        end
    end

    describe("imports by fully qualified path", function()
        local cases = {
            { "Circle(1.0)", "Circle", "fixtures.Circle" },
            { "aiTopFun(1)", "aiTopFun", "autoimport.lib.aiTopFun" },
            { "aiShout", "aiShout", "autoimport.lib.aiShout" },
            { "aiTopVal", "aiTopVal", "autoimport.lib.aiTopVal" },
            { "AI_TOP_CONST", "AI_TOP_CONST", "autoimport.lib.AI_TOP_CONST" },
            { "AI_MAX", "AI_MAX", "autoimport.lib.AiConsts.AI_MAX" },
            { "aiHelper", "aiHelper", "autoimport.lib.AiConsts.aiHelper" },
            { "AI_ONE", "AI_ONE", "autoimport.lib.AiOneLine.AI_ONE" },
            { "AiNested", "AiNested", "autoimport.lib.AiOuter.AiNested" },
            { "AI_COMP", "AI_COMP", "autoimport.lib.AiOuter.Companion.AI_COMP" },
            { "AI_RED", "AI_RED", "autoimport.lib.AiColor.AI_RED" },
            { "AI_LARGE", "AI_LARGE", "autoimport.lib.AiSize.AI_LARGE" },
            { "AI_LIMIT", "AI_LIMIT", "autoimport.lib.AiStatics.AI_LIMIT" },
            { "aiTwice", "aiTwice", "autoimport.lib.AiStatics.aiTwice" },
            { "AiInner", "AiInner", "autoimport.lib.AiStatics.AiInner" },
        }
        for _, c in ipairs(cases) do
            local needle, word, fq = unpack(c)
            it(word .. " -> " .. fq, function()
                assert.are.equal("import " .. fq, run("autoimport/Use.kt", needle, word))
            end)
        end
    end)

    describe("offers no import for", function()
        local cases = {
            { "ByteArray(16)", "ByteArray", "default-imported kotlin.ByteArray" },
            { "aiMember", "aiMember", "a class member after a dot" },
            { "aiHidden", "aiHidden", "a private top-level fun" },
            { "aiLocal", "aiLocal", "a local val" },
            { "aiCtorProp", "aiCtorProp", "a ctor property" },
            { "aiInstance", "aiInstance", "a java instance field" },
        }
        for _, c in ipairs(cases) do
            local needle, word, what = unpack(c)
            it(what, function()
                assert.is_nil(run("autoimport/Use.kt", needle, word))
                assert.is_nil(picked)
            end)
        end

        it("a class in the same package", function()
            assert.is_nil(run("Main.kt", "Circle(radius)", "Circle"))
            assert.truthy(note:find("same package", 1, true))
        end)
    end)

    it("same name in two packages -> picker", function()
        run("autoimport/Use.kt", "aiDup()", "aiDup")
        assert.are.same({ "autoimport.lib.aiDup", "autoimport.other.aiDup" }, picked)
    end)

    describe("placement", function()
        local buf
        before_each(function() buf = vim.api.nvim_create_buf(false, true) end)

        it("after the package line + a blank line", function()
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "package p", "", "fun x() = 1" })
            autoimport.insert(buf, "a.B")
            assert.are.same({ "package p", "", "import a.B", "", "fun x() = 1" },
                vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        end)

        it("no package -> top + a blank line", function()
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fun main() {", "}" })
            autoimport.insert(buf, "a.B")
            assert.are.same({ "import a.B", "", "fun main() {", "}" },
                vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        end)
    end)
end)
