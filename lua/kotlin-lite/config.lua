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
    -- in a gradle project, expose the `<leader>k` menu (run/sources/explorer/…)
    -- in every buffer, not only kotlin files
    project_keymaps = true,
    -- set 'tagfunc' in kotlin buffers: <C-]>, <C-w>], g], :tag, :ptag resolve
    -- like gd (as Neovim does for LSP buffers)
    tagfunc = true,
    -- on CursorHold, highlight the occurrences of the symbol under the cursor
    highlight_references = true,
    -- hint (greyed out) the imports nothing uses
    unused_imports = true,
    -- af / if (fun), ac / ic (class / object) text objects
    textobjects = false,
    -- also register IntelliJ-style keymaps on top of the vim ones
    intellij_keymaps = false,
    -- optional snacks.nvim explorer integration (compact middle packages etc.)
    snacks_integration = true,
    -- on startup, quietly extract the newest cached sources for common libs
    auto_extract = true,
    -- Android SDK for android code (nil: $ANDROID_HOME, $ANDROID_SDK_ROOT,
    -- local.properties sdk.dir, ~/Android/Sdk; false: none)
    android_sdk = nil,
    essentials = {
        -- always considered
        kotlin = {
            "kotlin-stdlib", "kotlin-reflect",
            "kotlinx-coroutines-core", "kotlinx-coroutines-core-jvm",
            "kotlinx-serialization-core", "kotlinx-serialization-json",
        },
        test = {
            "junit", "kotlin-test", "kotlin-test-junit",
            "kotlinx-coroutines-test", "turbine",
            "mockk", "mockito-core", "mockito-kotlin",
            "truth", "assertj-core", "robolectric",
        },
        -- only when an Android project is detected
        android = {
            "core", "core-ktx", "appcompat",
            "activity", "activity-ktx", "activity-compose",
            "fragment", "fragment-ktx",
            "lifecycle-runtime-ktx", "lifecycle-viewmodel-ktx",
            "material",
        },
        compose = {
            "ui", "ui-graphics", "ui-text", "ui-unit", "ui-tooling-preview",
            "foundation", "foundation-layout",
            "material3", "material-icons-core",
            "runtime", "animation", "navigation-compose",
        },
    },
    -- `run_file` / `run_project` terminal split
    run = {
        height = 15,
        -- gradle project property carrying the main class for `run_file`
        main_property = "mainClass",
    },
    -- `test_file` / `test_project`
    test = {
        task = nil,      -- override the gradle test task (auto: test / testDebugUnitTest)
        rerun = true,    -- prepend cleanTest so results & per-test output always refresh
        quickfix = true, -- list failed tests in the quickfix panel
    },
    -- lhs per action; a string or a list, false to disable
    -- The gr*/gO aliases shadow Neovim's default LSP maps in kotlin buffers only.
    keymaps = {
        goto_definition    = "gd",
        goto_type_definition = "grt",
        goto_implementation = "gri",           -- subtypes / overrides / actuals
        goto_super         = "<leader>ku",    -- IntelliJ Ctrl+U
        hover              = "K",
        signature_help     = "gK",
        signature_help_insert = "<C-s>", -- insert mode, like Neovim's LSP default
        find_usages        = { "gu", "grr" },  -- grr (references) alias
        incoming_calls     = "<leader>kh",    -- IntelliJ Ctrl+Alt+H
        next_reference     = "]r",
        prev_reference     = "[r",
        rename             = { "<leader>cr", "grn" }, -- grn (rename) alias
        rename_file        = "<leader>cR",
        format             = "<leader>cf",
        organize_imports   = "<leader>co",
        file_structure     = { "<leader>cs", "gO" }, -- gO (document_symbol) alias
        project_symbols    = "<leader>cS",
        reveal_in_explorer = "<leader>ke",
        alternate_file     = "<leader>ka",
        copy_fqname        = "<leader>kc",
        auto_import        = { "<leader>ki", "gra" }, -- gra (code_action) alias
        run_file           = "<leader>kr",
        run_project        = "<leader>kR",
        test_file          = "<leader>kt",
        test_project       = "<leader>kT",
        sources            = "<leader>ks",
        toggle_compact     = "<leader>km", -- snacks explorer; registered globally
        find_files         = "<leader><leader>",
    },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
    return M.options
end

return M
