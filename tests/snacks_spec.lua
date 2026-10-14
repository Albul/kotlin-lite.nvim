-- snacks.nvim is not on the test runtimepath: the integration must degrade
-- gracefully without it.
local h = require("helpers")
local snacks = require("kotlin-lite.snacks")
local config = require("kotlin-lite.config")

describe("snacks integration without snacks.nvim", function()
    after_each(h.reset)

    it("reveal() warns when enabled", function()
        config.setup({ snacks_integration = true })
        local note = h.capture_notify()
        snacks.reveal()
        assert.are.equal(vim.log.levels.WARN, note.level)
        assert.are.equal("kotlin-lite: 'snacks.nvim' is required for this feature, but it is not installed.", note.msg)
    end)

    it("reveal() is a silent no-op when disabled", function()
        config.setup({ snacks_integration = false })
        local note = h.capture_notify()
        snacks.reveal()
        assert.is_nil(note.msg)
    end)

    it("explorer_opts() is empty when disabled", function()
        config.setup({ snacks_integration = false })
        assert.are.same({}, snacks.explorer_opts())
    end)

    it("explorer_opts() exposes actions + transform when enabled", function()
        config.setup({ snacks_integration = true })
        local opts = snacks.explorer_opts()
        assert.is_table(opts.actions)
        assert.is_function(opts.transform)
    end)
end)

describe("clipboard file command", function()
    it("builds a uri-list stdin (or nil when no tool, e.g. headless w/o DISPLAY)", function()
        local spec = snacks._clipboard_file_command({ "/tmp/A.kt", "/tmp/B.kt" })
        if spec ~= nil then
            assert.is_table(spec.cmd)
            assert.are.equal("file:///tmp/A.kt\nfile:///tmp/B.kt\n", spec.stdin)
        end
    end)
end)
