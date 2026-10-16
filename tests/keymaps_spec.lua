local h = require("helpers")
local keymaps = require("kotlin-lite.keymaps")

local function buffer_local(lhs, mode)
    return vim.fn.maparg(lhs, mode or "n", false, true).buffer == 1
end

local function global(lhs)
    local m = vim.fn.maparg(lhs, "n", false, true)
    return next(m) ~= nil and m.buffer == 0
end

describe("keymaps in a kotlin buffer", function()
    before_each(function() h.open("Main.kt") end)
    after_each(h.reset)

    it("attach to the buffer", function()
        assert.is_true(vim.b.kotlin_lite_attached)
    end)

    for _, lhs in ipairs({ "gd", "gu", "grr", "<leader>ks", "<leader>kt" }) do
        it(lhs .. " is buffer-local", function()
            assert.is_true(buffer_local(lhs))
        end)
    end

    local aliases = { grn = "rename", grt = "type definition", gra = "auto-import", gO = "file structure" }
    for lhs, what in pairs(aliases) do
        it(lhs .. " alias (" .. what .. ") is buffer-local", function()
            assert.is_true(buffer_local(lhs))
        end)
    end

    it("<C-s> in insert mode is buffer-local signature help", function()
        local m = vim.fn.maparg("<C-s>", "i", false, true)
        assert.are.equal(1, m.buffer)
        assert.matches("Signature", m.desc)
    end)
end)

describe("keymaps outside kotlin", function()
    before_each(function()
        vim.cmd("enew")
        vim.bo.filetype = "lua"
    end)
    after_each(h.reset)

    it("gu is not mapped in a lua buffer", function()
        assert.is_false(buffer_local("gu"))
    end)

    it("the default grr LSP map stays global", function()
        assert.are_not.equal("", vim.fn.maparg("grr", "n"))
    end)
end)

describe("global keymaps", function()
    after_each(h.reset)

    describe("attach_globals(project_actions)", function()
        before_each(function()
            -- observe from a non-kotlin buffer so buffer-local maps don't shadow globals
            vim.cmd("enew")
            vim.bo.filetype = "lua"
            keymaps.attach_globals(keymaps.project_actions) -- as if in a gradle project
        end)
        after_each(function()
            for _, l in ipairs({ "<leader>ks", "<leader>kR", "<leader>ke", "<leader>kT" }) do
                pcall(vim.keymap.del, "n", l)
            end
        end)

        for _, lhs in ipairs({ "<leader>ks", "<leader>kR", "<leader>ke" }) do
            it("maps " .. lhs .. " globally", function()
                assert.is_true(global(lhs))
            end)
        end

        it("<leader>km (snacks compact toggle) is not mapped without snacks.nvim", function()
            assert.are.equal("", vim.fn.maparg("<leader>km", "n"))
        end)

        for _, lhs in ipairs({ "<leader>kr", "<leader>ka", "gd", "<leader>cs" }) do
            it("leaves kotlin-only " .. lhs .. " unmapped", function()
                assert.are.equal("", vim.fn.maparg(lhs, "n"))
            end)
        end
    end)

    it("test_project is a project action", function()
        assert.is_true(vim.tbl_contains(keymaps.project_actions, "test_project"))
    end)

    it("entering a gradle-project file attaches <leader>kR globally", function()
        pcall(vim.keymap.del, "n", "<leader>kR")
        vim.cmd("edit " .. vim.fn.fnameescape(h.fixtures .. "/runner/gradle/build.gradle.kts"))
        h.wait(function() return vim.fn.maparg("<leader>kR", "n") ~= "" end, 500)
        assert.are_not.equal("", vim.fn.maparg("<leader>kR", "n"))
    end)
end)
