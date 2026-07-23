-- Defaults and option merging. `M.options` is valid before setup() so every
-- module can read config unconditionally.

local M = {}

-- codicon glyph by codepoint (avoids embedding raw nerd-font bytes in source)
local function u(cp)
    return vim.fn.nr2char(cp)
end

M.defaults = {
    filetypes = { "kotlin" },
    cache_dir = vim.fn.stdpath("cache") .. "/kotlin-lite-jars",
    jar_search_roots = {
        "~/.gradle/caches/modules-2/files-2.1",
        "~/.m2/repository",
    },
    -- whole-buffer formatter for <leader>cf; stdin in, formatted source on stdout
    -- (--log-level=none keeps ktlint's log lines out of the buffer)
    formatprg = "ktlint --format --stdin --log-level=none",
    -- opt-in: also map `=` (normal + visual) to whole-buffer format. Off by
    -- default so `=` keeps Neovim's native reindent.
    format_on_equal = false,
    -- file-structure icons (nerd-font codicons; override with plain text if you
    -- don't use a nerd font)
    symbols = {
        icons = {
            class     = u(0xeb5b), --
            interface = u(0xeb61), --
            object    = u(0xea8b), --
            companion = u(0xea8b), --
            ["fun"]   = u(0xea8c), --
            field     = u(0xeb5f), --
        },
    },
    -- also register IntelliJ-style keymaps on top of the vim ones
    intellij_keymaps = false,
    -- optional snacks.nvim explorer integration (compact middle packages etc.)
    snacks_integration = true,
    -- on startup, quietly extract the newest cached sources for common libs
    auto_extract = true,
    essentials = {
        kotlin = {
            "kotlin-stdlib", "kotlin-reflect",
            "kotlinx-coroutines-core", "kotlinx-coroutines-core-jvm",
            "kotlinx-serialization-core", "kotlinx-serialization-json",
        },
        -- androidx module names (only used when an Android project is detected)
        android = {
            "core", "core-ktx", "appcompat",
            "activity", "activity-ktx", "activity-compose",
            "fragment", "fragment-ktx",
            "lifecycle-runtime-ktx", "lifecycle-viewmodel-ktx",
            "material",
        },
    },
    -- `run_file` / `run_project` terminal split
    run = {
        height = 15,
        -- gradle project property carrying the main class for `run_file`
        main_property = "mainClass",
    },
    -- lhs per action; a string or a list, false to disable
    keymaps = {
        goto_definition    = "gd",
        hover              = "K",
        signature_help     = "gK",
        -- gu + grr (grr shadows nvim's LSP references map in kotlin buffers only)
        find_usages        = { "gu", "grr" },
        rename             = "<leader>cr",
        rename_file        = "<leader>cR",
        format             = "<leader>cf",
        file_structure     = "<leader>cs",
        project_symbols    = "<leader>cS",
        reveal_in_explorer = "<leader>ke",
        alternate_file     = "<leader>ka",
        copy_fqname        = "<leader>kc",
        auto_import        = "<leader>ki",
        run_file           = "<leader>kr",
        run_project        = "<leader>kR",
        sources            = "<leader>ks",
        find_files         = "<leader><leader>",
    },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
    return M.options
end

return M
