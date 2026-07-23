-- User-facing navigation & editing actions.

local search = require("kotlin-lite.search")
local jars = require("kotlin-lite.jars")

local M = {}

local function cfg()
    return require("kotlin-lite.config").options
end

-------------------------------------------------------------------
-- shared helpers
-------------------------------------------------------------------

-- picker label: "[jar] path" for jar sources, project-relative otherwise
local function display(it)
    local f = it.filename
    if jars.is_jar(f) then
        f = "[jar] " .. (f:match("^" .. vim.pesc(cfg().cache_dir) .. "/[^/]+/(.*)$") or f)
    else
        f = vim.fn.fnamemodify(f, ":.")
    end
    return f .. ":" .. it.lnum .. "  " .. it.text
end
M.display = display

local function jump(it)
    vim.cmd("normal! m'")
    vim.cmd.edit(vim.fn.fnameescape(it.filename))
    pcall(vim.api.nvim_win_set_cursor, 0, { it.lnum, math.max((it.col or 1) - 1, 0) })
    vim.cmd("normal! zvzz")
end

-- prefer a project match over a jar match
local function best(items)
    for _, it in ipairs(items) do
        if not jars.is_jar(it.filename) then return it end
    end
    return items[1]
end

-- package declared in `file` (reads only the head of the file)
local function package_of(file)
    local ok, lines = pcall(vim.fn.readfile, file, "", 40)
    if not ok then return nil end
    for _, l in ipairs(lines) do
        local pkg = l:match("^%s*package%s+([%w_.]+)")
        if pkg then return pkg end
    end
    return nil
end

-------------------------------------------------------------------
-- goto definition (gd)
-------------------------------------------------------------------
function M.goto_definition()
    local word = vim.fn.expand("<cword>")
    if word == "" then return end

    if search.find_decl_in_buffer(word) then return end

    search.rg(search.decl_args(word), search.search_dirs(), function(items)
        if #items == 0 then
            vim.notify("kotlin-lite: no declaration found for '" .. word .. "'", vim.log.levels.WARN)
            return
        end
        local project = vim.tbl_filter(function(it) return not jars.is_jar(it.filename) end, items)
        local pick = #project > 0 and project or items
        if #pick == 1 then
            jump(pick[1])
        else
            vim.ui.select(pick, {
                prompt = "Definition: " .. word,
                format_item = display,
            }, function(choice)
                if choice then jump(choice) end
            end)
        end
    end)
end

-------------------------------------------------------------------
-- hover (K) and signature help (gK)
-------------------------------------------------------------------

-- KDoc + annotations + signature, cut until parens balance
local function doc_block(lines, lnum)
    local s, e = lnum, lnum
    if lines[lnum]:find("%(") then
        local bal = 0
        for i = lnum, math.min(lnum + 15, #lines) do
            local _, o = lines[i]:gsub("%(", "")
            local _, c = lines[i]:gsub("%)", "")
            bal = bal + o - c
            e = i
            if bal <= 0 then break end
        end
    end
    while s > 1 and lines[s - 1]:match("^%s*@") do s = s - 1 end
    if s > 1 and lines[s - 1]:match("%*/%s*$") then
        local k = s - 1
        while k > 1 and not lines[k]:match("/%*%*") do k = k - 1 end
        if lines[k]:match("/%*%*") then s = k end
    end
    local block = {}
    for i = s, e do table.insert(block, lines[i]) end
    return block
end

local function show_float(it)
    local ok, lines = pcall(vim.fn.readfile, it.filename)
    if not ok then return end
    local block = doc_block(lines, it.lnum)
    table.insert(block, "")
    table.insert(block, "-- " .. display(it))
    vim.lsp.util.open_floating_preview(block, "kotlin", {
        border = "rounded",
        max_width = 100,
        max_height = 30,
        focus_id = "kotlin-lite-hover",
    })
end

function M.hover()
    local word = vim.fn.expand("<cword>")
    if word == "" then return end
    search.rg(search.decl_args(word), search.search_dirs(), function(items)
        if #items == 0 then
            vim.notify("kotlin-lite: nothing found for '" .. word .. "'", vim.log.levels.WARN)
            return
        end
        show_float(best(items))
    end)
end

function M.signature_help()
    local pos = vim.fn.searchpairpos("(", "", ")", "bnW")
    if pos[1] == 0 then return M.hover() end
    local before = vim.fn.getline(pos[1]):sub(1, pos[2] - 1)
    local name = before:match("([%w_]+)%s*$")
    if not name then return M.hover() end
    local args = { "-e", [=[\bfun\s+(<[^>]*>\s+)?([\w.<>?,\s]+\.)?]=] .. name .. [=[\s*[(<]]=] }
    search.rg(args, search.search_dirs(), function(items)
        if #items == 0 then
            vim.notify("kotlin-lite: no signature found for '" .. name .. "'", vim.log.levels.WARN)
            return
        end
        show_float(best(items))
    end)
end

-------------------------------------------------------------------
-- find usages (gr) -> quickfix at the bottom
-------------------------------------------------------------------
function M.find_usages()
    local word = vim.fn.expand("<cword>")
    if word == "" then return end
    search.rg({ "-w", "-e", word }, { search.root() }, function(items)
        if #items == 0 then
            vim.notify("kotlin-lite: no usages of '" .. word .. "' found", vim.log.levels.INFO)
            return
        end
        vim.fn.setqflist({}, " ", { title = "Usages: " .. word, items = items })
        vim.cmd("botright copen 12")
    end)
end

-------------------------------------------------------------------
-- rename (<leader>cr): project-wide word search & replace
-------------------------------------------------------------------
function M.rename()
    local word = vim.fn.expand("<cword>")
    if word == "" then return end
    vim.ui.input({ prompt = "Rename '" .. word .. "' -> ", default = word }, function(new)
        if not new or new == "" or new == word then return end
        if not new:match("^[%a_][%w_]*$") then
            vim.notify("kotlin-lite: '" .. new .. "' is not a valid identifier", vim.log.levels.ERROR)
            return
        end
        search.rg({ "-w", "-e", word }, { search.root() }, function(items)
            if #items == 0 then
                vim.notify("kotlin-lite: nothing to replace", vim.log.levels.INFO)
                return
            end
            local files = {}
            for _, it in ipairs(items) do files[it.filename] = true end
            local msg = ("Replace %d occurrences of '%s' -> '%s' in %d files?")
                :format(#items, word, new, vim.tbl_count(files))
            if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then return end

            local cur_buf = vim.api.nvim_get_current_buf()
            local view = vim.fn.winsaveview()
            vim.fn.setqflist({}, " ", { title = "Rename: " .. word .. " -> " .. new, items = items })
            vim.cmd(("silent! cfdo %%s/\\V\\<%s\\>/%s/ge | update"):format(word, new))
            if vim.api.nvim_buf_is_valid(cur_buf) then
                vim.api.nvim_set_current_buf(cur_buf)
                vim.fn.winrestview(view)
            end
            vim.notify(("kotlin-lite: replaced in %d files"):format(vim.tbl_count(files)), vim.log.levels.INFO)
        end)
    end)
end

-------------------------------------------------------------------
-- file structure (Ctrl+F12) and go-to-symbol in project (Ctrl+N)
-------------------------------------------------------------------
local symbol_specs = {
    { kind = "fun",       pat = [=[\<fun\s\+\%(<[^>]*>\s\+\)\?\zs[A-Za-z0-9_.<>?, ]\{-}[A-Za-z0-9_]\ze\s*(]=] },
    { kind = "class",     pat = [=[\<class\s\+\zs[A-Za-z0-9_]\+]=] },
    { kind = "interface", pat = [=[\<interface\s\+\zs[A-Za-z0-9_]\+]=] },
    { kind = "object",    pat = [=[\<object\s\+\zs[A-Za-z0-9_]\+]=] },
    { kind = "typealias", pat = [=[\<typealias\s\+\zs[A-Za-z0-9_]\+]=] },
    { kind = "val",       pat = [=[\<val\s\+\%(<[^>]*>\s\+\)\?\zs[A-Za-z0-9_]\+]=] },
    { kind = "var",       pat = [=[\<var\s\+\%(<[^>]*>\s\+\)\?\zs[A-Za-z0-9_]\+]=] },
}

function M.file_structure()
    local buf = vim.api.nvim_get_current_buf()
    local items = {}
    for _, spec in ipairs(symbol_specs) do
        local ok, found = pcall(vim.fn.matchbufline, buf, spec.pat, 1, "$")
        if ok then
            for _, m in ipairs(found) do
                if not search.is_comment_line(buf, m.lnum) then
                    table.insert(items, {
                        lnum = m.lnum,
                        col = m.byteidx,
                        kind = spec.kind,
                        name = m.text,
                    })
                end
            end
        end
    end
    if #items == 0 then
        vim.notify("kotlin-lite: no symbols in this file", vim.log.levels.INFO)
        return
    end
    table.sort(items, function(a, b) return a.lnum < b.lnum end)
    vim.ui.select(items, {
        prompt = "File structure",
        format_item = function(it)
            return ("%s  [%s]  :%d"):format(it.name, it.kind, it.lnum)
        end,
    }, function(choice)
        if choice then
            vim.cmd("normal! m'")
            vim.api.nvim_win_set_cursor(0, { choice.lnum, choice.col })
            vim.cmd("normal! zvzz")
        end
    end)
end

function M.project_symbols()
    vim.ui.input({ prompt = "Symbol: " }, function(query)
        if not query or query == "" then return end
        if not query:match("^[%w_]+$") then
            vim.notify("kotlin-lite: only [A-Za-z0-9_] is supported in symbol search", vim.log.levels.WARN)
            return
        end
        local w = [=[\w*]=] .. query .. [=[\w*]=]
        search.rg(search.decl_args(w), search.search_dirs(), function(items)
            if #items == 0 then
                vim.notify("kotlin-lite: no symbols match '" .. query .. "'", vim.log.levels.INFO)
                return
            end
            if #items == 1 then
                jump(items[1])
                return
            end
            vim.ui.select(items, {
                prompt = "Symbols: " .. query,
                format_item = display,
            }, function(choice)
                if choice then jump(choice) end
            end)
        end)
    end)
end

-------------------------------------------------------------------
-- reveal current file in the snacks explorer (Alt+F1)
-------------------------------------------------------------------
function M.reveal_in_explorer()
    local ok, Snacks = pcall(require, "snacks")
    if not (ok and Snacks.explorer) then
        vim.notify("kotlin-lite: snacks.nvim explorer is not available", vim.log.levels.WARN)
        return
    end
    local picker
    if Snacks.explorer.reveal then
        picker = Snacks.explorer.reveal()
    else
        picker = Snacks.explorer()
    end
    if picker then pcall(function() picker:focus() end) end
end

-------------------------------------------------------------------
-- alternate file: src/main/kotlin/X.kt <-> src/test/kotlin/XTest.kt
-------------------------------------------------------------------
function M.alternate_file()
    local path = vim.api.nvim_buf_get_name(0)
    if path == "" then return end

    local target
    if path:find("src/main/kotlin/", 1, true) then
        target = path:gsub("src/main/kotlin/", "src/test/kotlin/"):gsub("%.kt$", "Test.kt")
    elseif path:find("src/test/kotlin/", 1, true) then
        target = path:gsub("src/test/kotlin/", "src/main/kotlin/"):gsub("Test%.kt$", ".kt")
    else
        vim.notify("kotlin-lite: not under src/main/kotlin or src/test/kotlin", vim.log.levels.WARN)
        return
    end

    if vim.fn.filereadable(target) == 0 then
        vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")
    end
    vim.cmd("normal! m'")
    vim.cmd.edit(vim.fn.fnameescape(target))
end

-------------------------------------------------------------------
-- copy fully-qualified name (package + file name) to the + register
-------------------------------------------------------------------
function M.copy_fqname()
    local name = vim.fn.expand("%:t:r")
    if name == "" then
        vim.notify("kotlin-lite: no file name", vim.log.levels.WARN)
        return
    end
    local pkg
    for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        pkg = l:match("^%s*package%s+([%w_.]+)")
        if pkg then break end
    end
    local fq = pkg and (pkg .. "." .. name) or name
    vim.fn.setreg("+", fq)
    vim.notify("kotlin-lite: copied " .. fq, vim.log.levels.INFO)
    return fq
end

-------------------------------------------------------------------
-- format via 'equalprg' (ktlint by default)
-------------------------------------------------------------------
function M.format_buffer()
    if vim.bo.equalprg == "" then
        vim.notify("kotlin-lite: no formatter set (equalprg)", vim.log.levels.WARN)
        return
    end
    local view = vim.fn.winsaveview()
    vim.cmd("silent keepjumps normal! gg=G")
    vim.fn.winrestview(view)
end

-------------------------------------------------------------------
-- auto-import the symbol under the cursor (Alt+Enter)
-------------------------------------------------------------------

-- insert `import <fq>` after the last existing import (or the package line)
local function insert_import(buf, fq)
    local import_line = "import " .. fq
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local last_import, pkg_line
    for i, l in ipairs(lines) do
        if l:match("^%s*import%s+") then
            if vim.trim(l) == import_line then
                vim.notify("kotlin-lite: '" .. fq .. "' already imported", vim.log.levels.INFO)
                return
            end
            last_import = i
        elseif l:match("^%s*package%s+") then
            pkg_line = i
        end
    end
    local at = last_import or pkg_line or 0
    vim.api.nvim_buf_set_lines(buf, at, at, false, { import_line })
    vim.notify("kotlin-lite: added " .. import_line, vim.log.levels.INFO)
end

function M.auto_import_under_cursor()
    local word = vim.fn.expand("<cword>")
    if word == "" or not word:match("^[%a_][%w_]*$") then return end

    local buf = vim.api.nvim_get_current_buf()
    local pat = [=[\b(class|interface|object|typealias)\s+]=] .. word .. [=[\b]=]
    local cmd = { "rg", "-l", "--no-messages", "-t", "kotlin", "-e", pat, search.root() }

    vim.system(cmd, { text = true }, function(res)
        vim.schedule(function()
            local files = vim.split(res.stdout or "", "\n", { trimempty = true })
            if #files == 0 then
                vim.notify("kotlin-lite: no definition found for '" .. word .. "'", vim.log.levels.WARN)
                return
            end
            -- unique candidate imports (a package may host several matching files)
            local imports, seen = {}, {}
            for _, f in ipairs(files) do
                local pkg = package_of(f)
                local imp = pkg and (pkg .. "." .. word) or word
                if not seen[imp] then
                    seen[imp] = true
                    table.insert(imports, imp)
                end
            end
            if #imports == 1 then
                insert_import(buf, imports[1])
            else
                vim.ui.select(imports, { prompt = "Import " .. word .. ":" }, function(choice)
                    if choice then insert_import(buf, choice) end
                end)
            end
        end)
    end)
end

-------------------------------------------------------------------
-- file finder (IntelliJ Ctrl+N), best-effort across common pickers
-------------------------------------------------------------------
function M.find_files()
    local ok, telescope = pcall(require, "telescope.builtin")
    if ok then return telescope.find_files() end
    local ok2, Snacks = pcall(require, "snacks")
    if ok2 and Snacks.picker then return Snacks.picker.files() end
    vim.cmd("edit .")
end

return M
