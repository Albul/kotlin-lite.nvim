-- Folds from treesitter (foldexpr = vim.treesitter.foldexpr()): what the
-- plugin's queries/kotlin/folds.scm adds.

local h = require("helpers")

local PARSER = vim.fn.expand("~/.local/share/nvim/site/parser/kotlin.so")
local function load(opts)
    local ok, added = pcall(vim.treesitter.language.add, "kotlin", opts)
    return ok and added
end
local has_parser = load() or (vim.fn.filereadable(PARSER) == 1 and load({ path = PARSER }))

-- the fold that closes on line `lnum` -> "from-to"
local function fold_at(lnum)
    h.open("folds/Folds.kt")
    vim.wo.foldmethod = "expr"
    vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
    vim.wo.foldenable = true
    vim.wo.foldlevel = 99
    vim.treesitter.get_parser(0, "kotlin"):parse()
    vim.cmd("normal! zx")
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    vim.cmd("silent! normal! zc")
    return vim.fn.foldclosed(lnum) .. "-" .. vim.fn.foldclosedend(lnum)
end

describe("folds", function()
    after_each(h.reset)

    local cases = {
        { "KDoc", 3, "3-6" },
        { "block comment", 35, "35-36" },
        { "arguments of a call", 11, "11-14" },
        { "parameters of a fun", 26, "26-29" },
        { "try body", 17, "17-18" },
        { "catch", 19, "19-20" },
        { "finally", 21, "21-23" },
        { "a multi-line string", 31, "31-33" },
    }
    for _, c in ipairs(cases) do
        local name, lnum, want = unpack(c)
        local test = has_parser and it or pending
        test(name, function()
            assert.are.equal(want, fold_at(lnum))
        end)
    end

    local test = has_parser and it or pending
    test("a one-line call: no fold of its own", function()
        fold_at(37)
        assert.does_not.match("^>", tostring(vim.treesitter.foldexpr(37)))
    end)
end)

describe("folds of a buffer open before the plugin loads", function()
    local repo = vim.fn.fnamemodify(h.fixtures, ":h:h")

    after_each(function()
        vim.opt.rtp:append(repo)
        h.reset()
    end)

    local test = has_parser and it or pending
    test("are recomputed when it loads inside an autocmd (lazy's VeryLazy)", function()
        vim.opt.rtp:remove(repo)
        h.open("folds/Folds.kt")
        vim.wo.foldmethod = "expr"
        vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
        vim.treesitter.get_parser(0, "kotlin"):parse()
        assert.are.equal("0", tostring(vim.treesitter.foldexpr(3)))

        vim.api.nvim_create_autocmd("User", {
            pattern = "KotlinLiteLoad",
            once = true,
            callback = function()
                vim.opt.rtp:append(repo)
                require("kotlin-lite").setup({})
            end,
        })
        vim.api.nvim_exec_autocmds("User", { pattern = "KotlinLiteLoad" })
        h.wait(function() return tostring(vim.treesitter.foldexpr(3)) == ">1" end)
        assert.are.equal(">1", tostring(vim.treesitter.foldexpr(3)))
    end)
end)
