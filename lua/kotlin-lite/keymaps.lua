-- Buffer-local keymaps + 'equalprg', attached once per kotlin buffer.

local M = {}

-- action name -> { handler, description }
local function specs(actions)
    return {
        goto_definition    = { actions.goto_definition,        "Definition (kotlin-lite)" },
        hover              = { actions.hover,                   "Hover (kotlin-lite)" },
        signature_help     = { actions.signature_help,         "Signature (kotlin-lite)" },
        find_usages        = { actions.find_usages,            "Usages (kotlin-lite)" },
        rename             = { actions.rename,                 "Rename (kotlin-lite)" },
        file_structure     = { actions.file_structure,         "File structure (kotlin-lite)" },
        project_symbols    = { actions.project_symbols,        "Project symbols (kotlin-lite)" },
        reveal_in_explorer = { actions.reveal_in_explorer,     "Reveal in explorer (kotlin-lite)" },
        alternate_file     = { actions.alternate_file,         "Alternate file (kotlin-lite)" },
        copy_fqname        = { actions.copy_fqname,            "Copy FQ name (kotlin-lite)" },
        auto_import        = { actions.auto_import_under_cursor, "Auto-import (kotlin-lite)" },
    }
end

function M.attach(buf)
    if vim.b[buf].kotlin_lite_attached then return end
    vim.b[buf].kotlin_lite_attached = true

    local opts = require("kotlin-lite.config").options
    local actions = require("kotlin-lite.actions")
    local handlers = specs(actions)

    if opts.formatprg and opts.formatprg ~= "" then
        vim.bo[buf].equalprg = opts.formatprg
    end

    local function map(lhs, fn, desc)
        vim.keymap.set({ "n" }, lhs, fn, { buffer = buf, silent = true, desc = desc })
    end

    for name, lhs in pairs(opts.keymaps) do
        local spec = handlers[name]
        if spec and lhs then
            local list = type(lhs) == "table" and lhs or { lhs }
            for _, l in ipairs(list) do
                map(l, spec[1], spec[2])
            end
        end
    end

    if opts.intellij_keymaps then
        map("<C-n>", actions.find_files, "Find files (IntelliJ)")
        map("<S-F6>", actions.rename, "Rename (IntelliJ)")
        map("<C-A-l>", actions.format_buffer, "Format (IntelliJ)")
        map("<C-S-t>", actions.alternate_file, "Go to test (IntelliJ)")
        map("<M-CR>", actions.auto_import_under_cursor, "Auto-import (IntelliJ)")
    end
end

return M
