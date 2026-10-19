-- Unused imports (hint diagnostics, greyed out like an LSP's) and Organize
-- Imports: drop them, sort the rest the way ktlint / IntelliJ do.

local scope = require("kotlin-lite.scope")

local M = {}

M.ns = vim.api.nvim_create_namespace("kotlin-lite-imports")

-- used through syntax, never by name: `by`, `+`, `a[i]`, `for (x in y)`,
-- destructuring, `f()`
local OPERATORS = {}
for w in ([[getValue setValue provideDelegate plus minus times div rem mod rangeTo rangeUntil
    contains get set invoke iterator next hasNext compareTo equals inc dec unaryPlus unaryMinus
    not plusAssign minusAssign timesAssign divAssign remAssign modAssign]]):gmatch("%S+") do
    OPERATORS[w] = true
end

-- the header's imports: { lnum, text, path, name } (name: the alias, if any,
-- else the last segment; nil for a star import or a `backticked` one), and
-- the first line after them
local function header(mask, lines)
    local out, body = {}, 1
    for l, m in ipairs(mask) do
        local rest = m:match("^%s*import%s+(.-)%s*;?%s*$")
        if rest then
            local path, alias = rest:match("^([%w_.]+)%s+as%s+([%w_]+)$")
            path = path or rest:match("^[%w_.]+$")
            local name = alias or (path and path:match("([%w_]+)$"))
            out[#out + 1] = { lnum = l, text = vim.trim(lines[l]), path = rest, name = name }
            body = l + 1
        elseif m:match("^%s*[%a@]") and not m:match("^%s*package%s") and not m:match("^%s*@file") then
            break
        end
    end
    return out, body
end

-- names the code mentions after the header, and the ones KDoc links to ([Foo])
local function mentioned(mask, lines, from)
    local names = {}
    for l = from, #mask do
        for w in mask[l]:gmatch("[%a_][%w_]*") do names[w] = true end
        for w in lines[l]:gmatch("%[([%a_][%w_]*)") do names[w] = true end
    end
    return names
end

--- the imports of `lines` nothing uses, and repeated ones: { lnum, text, path, name }
function M.unused(lines)
    local mask = scope.mask(lines)
    local imports, body = header(mask, lines)
    local names = mentioned(mask, lines, body)
    local out, seen = {}, {}
    for _, i in ipairs(imports) do
        local name = i.name
        if seen[i.path] then
            out[#out + 1] = i
        elseif name and not names[name] and not OPERATORS[name] and not name:match("^component%d+$") then
            out[#out + 1] = i
        end
        seen[i.path] = true
    end
    return out
end

--- set the buffer's unused-import hints
function M.refresh(buf)
    buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
    local diags = {}
    for _, i in ipairs(M.unused(vim.api.nvim_buf_get_lines(buf, 0, -1, false))) do
        diags[#diags + 1] = {
            lnum = i.lnum - 1,
            col = 0,
            end_col = #i.text,
            severity = vim.diagnostic.severity.HINT,
            message = "Unused import " .. i.path:gsub("%s+as%s+.*", ""),
            source = "kotlin-lite",
            _tags = { unnecessary = true },
        }
    end
    vim.diagnostic.set(M.ns, buf, diags)
end

--- keep the hints up to date: on entering the buffer, after normal-mode edits,
--- on leaving insert mode
function M.attach(buf)
    vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "InsertLeave" }, {
        group = vim.api.nvim_create_augroup("kotlin-lite-imports-" .. buf, { clear = true }),
        buffer = buf,
        callback = function() M.refresh(buf) end,
    })
    M.refresh(buf)
end

-- ktlint's default layout: everything else, java, javax, kotlin, then aliases
local function group(path)
    if path:match("%sas%s") then return 5 end
    for g, prefix in ipairs({ "java", "javax", "kotlin" }) do
        if path == prefix or path:sub(1, #prefix + 1) == prefix .. "." then return g + 1 end
    end
    return 1
end

local function before(a, b)
    local ga, gb = group(a.path), group(b.path)
    if ga ~= gb then return ga < gb end
    return a.path < b.path
end

--- drop the unused imports, sort the rest; a block with comments in it only
--- loses the unused lines
function M.organize(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local imports = header(scope.mask(lines), lines)
    if #imports == 0 then return end
    local first, last = imports[1].lnum, imports[#imports].lnum

    local gone = {}
    for _, i in ipairs(M.unused(lines)) do gone[i.lnum] = true end

    local kept, sortable = {}, true
    for l = first, last do
        if not gone[l] then
            local imp = vim.tbl_filter(function(i) return i.lnum == l end, imports)[1]
            if imp then
                kept[#kept + 1] = imp
            elseif vim.trim(lines[l]) ~= "" then
                sortable = false
            end
        end
    end

    local block
    if sortable then
        table.sort(kept, before)
        block = vim.tbl_map(function(i) return "import " .. i.path end, kept)
    else
        block = {}
        for l = first, last do
            if not gone[l] then block[#block + 1] = lines[l] end
        end
    end

    -- without imports, the blank line that followed them goes too
    if #block == 0 and (lines[last + 1] or "") == "" and (first == 1 or lines[first - 1] == "") then
        last = last + 1
    end
    if vim.deep_equal(block, vim.list_slice(lines, first, last)) then return end
    vim.api.nvim_buf_set_lines(buf, first - 1, last, false, block)
    M.refresh(buf)
end

return M
