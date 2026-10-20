-- Treesitter highlights: what the plugin's queries/kotlin/highlights.scm adds.

local h = require("helpers")

local PARSER = vim.fn.expand("~/.local/share/nvim/site/parser/kotlin.so")
local function load(opts)
    local ok, added = pcall(vim.treesitter.language.add, "kotlin", opts)
    return ok and added
end
local has_parser = load() or (vim.fn.filereadable(PARSER) == 1 and load({ path = PARSER }))

local LINE = 'fun f(entryPath: String) = "\'$entryPath\' is ${entryPath.length}"'

-- a kotlin buffer with LINE, highlighted by treesitter
local function open()
    h.open("folds/Folds.kt")
    vim.bo.modifiable = true
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { LINE })
    vim.treesitter.start(0, "kotlin")
    vim.treesitter.get_parser(0):parse(true)
end

-- captures at the first `text` of LINE (0-based column of its start)
local function captures(text)
    local col = LINE:find(text, 1, true) - 1
    return vim.tbl_map(function(c) return c.capture end, vim.treesitter.get_captures_at_pos(0, 0, col))
end

describe("treesitter highlights", function()
    after_each(h.reset)
    local test = has_parser and it or pending

    test("$name in a string: the $ and the name, not just the string", function()
        open()
        assert.is_true(vim.tbl_contains(captures("$entryPath"), "punctuation.special"))
        assert.is_true(vim.tbl_contains(captures("entryPath'"), "variable"))
        assert.is_false(vim.tbl_contains(captures("' is"), "variable"))
    end)
end)

describe("highlights of a buffer open before the plugin loads", function()
    local repo = vim.fn.fnamemodify(h.fixtures, ":h:h")

    after_each(function()
        vim.opt.rtp:append(repo)
        h.reset()
    end)

    local test = has_parser and it or pending
    test("are redone when it loads inside an autocmd (lazy's VeryLazy)", function()
        vim.opt.rtp:remove(repo)
        open()
        assert.is_false(vim.tbl_contains(captures("entryPath'"), "variable"))

        vim.api.nvim_create_autocmd("User", {
            pattern = "KotlinLiteLoad",
            once = true,
            callback = function()
                vim.opt.rtp:append(repo)
                require("kotlin-lite").setup({})
            end,
        })
        vim.api.nvim_exec_autocmds("User", { pattern = "KotlinLiteLoad" })
        assert.is_true(h.wait(function()
            local p = vim.treesitter.get_parser(0)
            if p then p:parse(true) end
            return vim.tbl_contains(captures("entryPath'"), "variable")
        end))
    end)
end)
