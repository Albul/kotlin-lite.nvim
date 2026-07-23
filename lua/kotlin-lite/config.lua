-- Defaults and option merging. `M.options` is valid before setup() so every
-- module can read config unconditionally.

local M = {}

M.defaults = {
    filetypes = { "kotlin" },
    cache_dir = vim.fn.stdpath("cache") .. "/kotlin-lite-jars",
    jar_search_roots = {
        "~/.gradle/caches/modules-2/files-2.1",
        "~/.m2/repository",
    },
    -- buffer-local 'equalprg' for kotlin, driving the `=` operator
    formatprg = "ktlint --format --stdin",
    -- also register IntelliJ-style keymaps on top of the vim ones
    intellij_keymaps = false,
    -- lhs per action; a string or a list, false to disable
    keymaps = {
        goto_definition    = "gd",
        hover              = "K",
        signature_help     = "gK",
        find_usages        = { "gr", "<leader>fu" },
        rename             = "<leader>cr",
        file_structure     = "<leader>cs",
        project_symbols    = "<leader>cS",
        reveal_in_explorer = "<leader>fe",
        alternate_file     = "<leader>ka",
        copy_fqname        = "<leader>kc",
        auto_import        = "<leader>ki",
    },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
    return M.options
end

return M
