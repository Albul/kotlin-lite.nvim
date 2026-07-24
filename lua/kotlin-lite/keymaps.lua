-- Buffer-local keymaps + 'equalprg', attached once per kotlin buffer.

local M = {}

-- action name -> { handler, description }
local function specs()
    local actions = require("kotlin-lite.actions")
    local runner = require("kotlin-lite.runner")
    return {
        goto_definition    = { actions.goto_definition,        "Definition (kotlin-lite)" },
        hover              = { actions.hover,                   "Hover (kotlin-lite)" },
        signature_help     = { actions.signature_help,         "Signature (kotlin-lite)" },
        find_usages        = { actions.find_usages,            "Usages (kotlin-lite)" },
        rename             = { actions.rename,                 "Rename symbol (kotlin-lite)" },
        rename_file        = { actions.rename_file,            "Rename file (kotlin-lite)" },
        format             = { actions.format_buffer,          "Format buffer (kotlin-lite)" },
        file_structure     = { actions.file_structure,         "File structure (kotlin-lite)" },
        project_symbols    = { actions.project_symbols,        "Project symbols (kotlin-lite)" },
        reveal_in_explorer = { function() require("kotlin-lite.snacks").reveal() end, "Reveal in explorer (kotlin-lite)" },
        alternate_file     = { actions.alternate_file,         "Alternate file (kotlin-lite)" },
        copy_fqname        = { actions.copy_fqname,            "Copy FQ name (kotlin-lite)" },
        auto_import        = { actions.auto_import_under_cursor, "Auto-import (kotlin-lite)" },
        run_file           = { runner.run_file,                "Run file (kotlin-lite)" },
        run_project        = { runner.run_project,             "Run project (kotlin-lite)" },
        test_file          = { runner.run_tests_file,          "Test file (kotlin-lite)" },
        test_project       = { runner.run_tests_project,       "Test project (kotlin-lite)" },
        sources            = { function() require("kotlin-lite.jars").pick_sources_jar() end, "Extract sources jar (kotlin-lite)" },
        toggle_compact     = { function() require("kotlin-lite.snacks").toggle_compact() end, "Toggle compact packages (kotlin-lite)" },
        find_files         = { actions.find_files,             "Find files (kotlin-lite)" },
    }
end

-- project-level actions that are useful without a .kt buffer; registered
-- globally (leader maps, so they don't shadow LSP defaults elsewhere)
M.project_actions = { "run_project", "test_project", "sources", "reveal_in_explorer" }
-- registered globally too, but gated on snacks rather than a gradle root
M.snacks_actions = { "toggle_compact" }
-- never attached buffer-locally (only ever global)
local GLOBAL_ONLY = { toggle_compact = true }

--- Register the given action names as global (not buffer-local) normal maps.
function M.attach_globals(names)
    local keymaps = require("kotlin-lite.config").options.keymaps
    local handlers = specs()
    for _, name in ipairs(names) do
        local lhs, spec = keymaps[name], handlers[name]
        if lhs and spec then
            for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
                vim.keymap.set("n", l, spec[1], { silent = true, desc = spec[2] })
            end
        end
    end
end

function M.attach(buf)
    if vim.b[buf].kotlin_lite_attached then return end
    vim.b[buf].kotlin_lite_attached = true

    local opts = require("kotlin-lite.config").options
    local actions = require("kotlin-lite.actions")
    local runner = require("kotlin-lite.runner")
    local handlers = specs()

    local function map(lhs, rhs, desc, mode, remap)
        vim.keymap.set(mode or "n", lhs, rhs, {
            buffer = buf, silent = true, remap = remap or false, desc = desc,
        })
    end

    for name, lhs in pairs(opts.keymaps) do
        local spec = handlers[name]
        if spec and lhs and not GLOBAL_ONLY[name] then
            local list = type(lhs) == "table" and lhs or { lhs }
            for _, l in ipairs(list) do
                map(l, spec[1], spec[2])
            end
        end
    end

    -- `=` (normal + visual) formats the whole buffer via ktlint (see format_buffer)
    if opts.format_on_equal and opts.formatprg and opts.formatprg ~= "" then
        map("=", actions.format_buffer, "Format buffer (kotlin-lite)", { "n", "x" })
    end

    if opts.intellij_keymaps then
        map("<C-n>", actions.find_files, "Find files (IntelliJ)")
        map("<S-F6>", actions.rename, "Rename symbol (IntelliJ)")
        map("<C-A-l>", actions.format_buffer, "Format (IntelliJ)")
        map("<C-S-t>", actions.alternate_file, "Go to test (IntelliJ)")
        map("<M-CR>", actions.auto_import_under_cursor, "Auto-import (IntelliJ)")
        map("<C-e>", actions.recent_files, "Recent files (IntelliJ)")
        map("<S-F10>", runner.run_project, "Run project (IntelliJ)")
        map("<C-S-F10>", runner.run_file, "Run file (IntelliJ)")
        -- comment toggle via built-in gc; many terminals send <C-/> as <C-_>
        map("<C-_>", "gcc", "Comment line (IntelliJ)", "n", true)
        map("<C-/>", "gcc", "Comment line (IntelliJ)", "n", true)
        map("<C-_>", "gc", "Comment (IntelliJ)", "x", true)
        map("<C-/>", "gc", "Comment (IntelliJ)", "x", true)
        -- collapse / expand all folds (Ctrl+Shift+- / Ctrl+Shift+=; terminal-dependent)
        map("<C-S-->", "zM", "Collapse all folds (IntelliJ)")
        map("<C-S-=>", "zR", "Expand all folds (IntelliJ)")
    end
end

return M
