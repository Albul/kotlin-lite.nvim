-- Auto-import the symbol under the cursor (IntelliJ Alt+Enter).
--
-- Finds every importable declaration of the word in the project + extracted
-- jar sources -- types (incl. nested), top-level fun / val / const val (incl.
-- extensions), members of named / companion objects, enum entries and Java
-- static members -- and turns each into its fully qualified import path from
-- the file's package plus its enclosing declarations (found by indentation).
-- Declarations the file already sees (default imports, same package, star
-- import, explicit import) are not offered.

local search = require("kotlin-lite.search")
local imports = require("kotlin-lite.imports")
local jars = require("kotlin-lite.jars")
local defs = require("kotlin-lite.defs")

local M = {}

local function indent(line)
    return #(line:match("^%s*"))
end

local function has_word(s, w)
    return s:find("%f[%w_]" .. w .. "%f[^%w_]") ~= nil
end

-- rg patterns for `w` beyond search.decl_patterns (rust regex)
local function extra_patterns(w)
    return {
        -- enum entry on its own line: RED, / RED("x") / RED { ... } / RED;
        [=[^\s+]=] .. w .. [=[\s*(\(|\{|,|;|$)]=],
        -- one-line enum: enum class Color { RED, GREEN }
        [=[\benum\s+(class\s+)?\w+[^{]*\{[^}]*\b]=] .. w .. [=[\b]=],
        -- java: enum / record, static field or method
        [=[\b(enum|record)\s+]=] .. w .. [=[\b]=],
        [=[\bstatic\b[^=(]*\b]=] .. w .. [=[\s*[(=;]]=],
    }
end

-- Declaration a header line opens: { kind = "class"|"enum"|"object", name },
-- or nil when the line opens anything else (fun body, init, anonymous object).
function M.header_of(line)
    local s = line:gsub("//.*$", ""):gsub("::class", "")
    local comp = s:match("%f[%w_]companion%s+object%f[^%w_](.*)$")
    if comp then
        return { kind = "object", name = comp:match("^%s+([%a_][%w_]*)") or "Companion" }
    end
    local name = s:match("%f[%w_]enum%s+class%s+([%a_][%w_]*)") or s:match("%f[%w_]enum%s+([%a_][%w_]*)")
    if name and name ~= "class" then return { kind = "enum", name = name } end
    name = s:match("%f[%w_]object%s+([%a_][%w_]*)")
    if name then return { kind = "object", name = name } end
    for _, k in ipairs({ "class", "interface", "record" }) do
        name = s:match("%f[%w_]" .. k .. "%s+([%a_][%w_]*)")
        if name then return { kind = "class", name = name } end
    end
    return nil
end

local function skippable(s)
    return s == "" or s:match("^[})%]]") or s:sub(1, 1) == "*" or s:sub(1, 2) == "//"
        or s:sub(1, 2) == "/*" or s:sub(1, 1) == "@"
end

-- lines a header can run on for
local CONTINUATION = 8

-- line `l` (no header itself) continues a header left open above, at its
-- indent: the line of that header, else nil. `internal constructor(...) :`
-- after `class X`, a lone `{` after `interface X` + `extends ...`; not a
-- secondary constructor (`: this(...)`) or a statement: what lies between
-- holds no brace or `;`
local function continued(lines, l)
    local own = vim.trim(lines[l])
    local delegate = own:match("%f[%w_]constructor%s*%b()%s*:%s*([%a]+)%s*%(")
    if delegate == "this" or delegate == "super" then return nil end
    for k = l - 1, math.max(1, l - CONTINUATION), -1 do
        local s = vim.trim((lines[k]:gsub("//.*$", "")))
        if not skippable(s) then
            if M.header_of(s) then
                return not s:find("{", 1, true) and indent(lines[k]) == indent(lines[l]) and k or nil
            end
            if s:find("[{};]") then return nil end
        end
    end
    return nil
end

--- Enclosing declarations of line `lnum`, innermost first, with their header
--- lines. nil when the line is local (inside a fun / init / getter / lambda).
function M.owners(lines, lnum)
    local chain = {}
    local want = indent(lines[lnum] or "")
    local l = lnum - 1
    while want > 0 and l >= 1 do
        local line = lines[l]
        local s = vim.trim(line)
        if not skippable(s) and indent(line) < want then
            local h = M.header_of(line)
            if not h then
                -- a header on several lines: the line that names it
                local k = continued(lines, l)
                if not k then return nil end
                l, line = k, lines[k]
                s = vim.trim(line)
                h = M.header_of(line)
            end
            h.text = s
            chain[#chain + 1] = h
            want = indent(line)
        end
        l = l - 1
    end
    if want > 0 then return nil end
    return chain
end

local function is_private(text, in_jar)
    return has_word(text, "private") or has_word(text, "protected") or (in_jar and has_word(text, "internal"))
end

--- What the rg hit at `lines[lnum]` declares under the name `word`:
--- { kind = "type"|"fun"|"prop"|"entry", path = { "Outer", ..., word }, ext = bool }
--- or nil when it can't be imported (class member, local, private, comment).
function M.classify(lines, lnum, word, opts)
    opts = opts or {}
    local text = lines[lnum] or ""
    local s = vim.trim(text)
    if search.is_comment_text(text) then return nil end
    local w = vim.pesc(word)

    local kind, ext, self_owner
    if s:match("%f[%w_]enum%s+class%s+[%w_]+[^{]*{[^}]*%f[%w_]" .. w .. "%f[^%w_]")
        or (opts.java and s:match("%f[%w_]enum%s+[%w_]+[^{]*{[^}]*%f[%w_]" .. w .. "%f[^%w_]")) then
        kind, self_owner = "entry", M.header_of(text)
    elseif s:match("%f[%w_]typealias%s+" .. w .. "%f[^%w_]") then
        kind = "type"
    elseif (M.header_of(text) or {}).name == word then
        kind = "type"
    elseif not opts.java and s:match("%f[%w_]fun%f[^%w_]") then
        kind = "fun"
        ext = s:match("%f[%w_]fun%s+[^(]-%." .. w .. "%s*[(<]") ~= nil
    elseif not opts.java and s:match("%f[%w_]va[lr]%f[^%w_]") then
        kind = "prop"
        ext = s:match("%f[%w_]va[lr]%s+[^=:]-%." .. w .. "[%s:=]") ~= nil
            or s:match("%f[%w_]va[lr]%s+[^=:]-%." .. w .. "$") ~= nil
    elseif opts.java and has_word(s, "static") then
        kind = s:match(w .. "%s*%(") and "fun" or "prop"
    elseif s:match("^" .. w .. "%s*[({,;]") or s:match("^" .. w .. "%s*$") then
        kind = "entry"
    else
        return nil
    end
    if is_private(s, opts.jar) then return nil end
    -- fun / val on a header line: a ctor property (class member) or, after the
    -- `{` of a one-line object, a member of that object
    local h = (kind == "fun" or kind == "prop") and M.header_of(text)
    if h then
        local body = s:match("{(.*)$")
        if h.kind ~= "object" or not body or not has_word(body, word) then return nil end
        self_owner = h
    end

    local chain = M.owners(lines, lnum)
    if not chain then return nil end
    if self_owner then
        self_owner.text = s
        table.insert(chain, 1, self_owner)
    end
    for _, h in ipairs(chain) do
        if is_private(h.text, opts.jar) then return nil end
    end

    local inner = chain[1]
    if kind == "entry" then
        if not inner or inner.kind ~= "enum" then return nil end
    elseif kind == "fun" or kind == "prop" then
        -- importable at top level, as a member of an object, or as a java static
        if inner and inner.kind ~= "object" and not opts.java then return nil end
    end

    local path = {}
    for i = #chain, 1, -1 do path[#path + 1] = chain[i].name end
    path[#path + 1] = word
    return { kind = kind, path = path, ext = ext or false }
end

-- the cursor word is a member access: `x.word`, `x?.word`, or `.word` opening a line
local function dotted(line, col)
    return line:sub(1, col):match("%.%s*$") ~= nil
end

-- start column (0-based) of the word under the cursor
local function word_start(line, col)
    local s = col + 1
    while s > 1 and line:sub(s - 1, s - 1):match("[%w_]") do s = s - 1 end
    return s - 1
end

--- How the file (header `ctx`) already sees `cand`, or nil when it needs an import.
local function visible(ctx, cand)
    if ctx.explicit[cand.word] == cand.qualifier then return "imported" end
    for _, w in ipairs(ctx.wildcards) do
        if w == cand.qualifier then return w .. ".*" end
    end
    if cand.toplevel then
        if cand.qualifier == ctx.package then return "same package" end
        if imports.DEFAULT[cand.qualifier] then return cand.qualifier end
    end
    return nil
end

-------------------------------------------------------------------
-- inserting the import
-------------------------------------------------------------------

-- `import <fq>` after the last import, else after the package line (blank line
-- between), else at the top (blank line before the code)
function M.insert(buf, fq)
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
        elseif l:match("^%s*[%a@]") and not l:match("^%s*@file") then
            break -- first declaration: the header is over
        end
    end
    if last_import then
        vim.api.nvim_buf_set_lines(buf, last_import, last_import, false, { import_line })
    elseif pkg_line then
        vim.api.nvim_buf_set_lines(buf, pkg_line, pkg_line, false, { "", import_line })
    else
        local add = { import_line }
        if (lines[1] or "") ~= "" then add[2] = "" end
        vim.api.nvim_buf_set_lines(buf, 0, 0, false, add)
    end
    vim.notify("kotlin-lite: added " .. import_line, vim.log.levels.INFO)
end

-------------------------------------------------------------------
-- candidates
-------------------------------------------------------------------

--- rg items -> unique importable candidates
--- { fq, qualifier, word, kind, ext, toplevel, item }, project first then by fq.
function M.candidates(items, word)
    local files, out, seen = {}, {}, {}
    for _, it in ipairs(defs.latest_only(items)) do
        local f = files[it.filename]
        if not f then
            local ok, lines = pcall(vim.fn.readfile, it.filename)
            f = { lines = ok and lines or {}, pkg = imports.package_of(it.filename) }
            files[it.filename] = f
        end
        local c = M.classify(f.lines, it.lnum, word, {
            java = it.filename:match("%.java$") ~= nil,
            jar = jars.is_jar(it.filename),
        })
        if c then
            local qual = table.concat(c.path, ".", 1, #c.path - 1)
            if f.pkg then qual = qual == "" and f.pkg or (f.pkg .. "." .. qual) end
            if qual ~= "" then
                local fq = qual .. "." .. word
                if not seen[fq] then
                    seen[fq] = true
                    out[#out + 1] = {
                        fq = fq, qualifier = qual, word = word, kind = c.kind, ext = c.ext,
                        toplevel = #c.path == 1, item = it, jar = jars.is_jar(it.filename),
                    }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.jar ~= b.jar then return not a.jar end
        return a.fq < b.fq
    end)
    return out
end

local function label(c)
    local d = defs.describe(c.item, {})
    local sig = d.sig
    if #sig > 70 then sig = sig:sub(1, 69) .. "…" end
    return ("%s — %s  (%s)"):format(c.fq, sig, d.origin)
end

-------------------------------------------------------------------
-- entry point
-------------------------------------------------------------------

-- why the word needs no import (member in reach, decl of this file), or nil
local function in_reach(ctx, E)
    local res = require("kotlin-lite.resolve").resolve(ctx, E)
    if res.here then return "declared in this file" end
    if res.jump and res.jump.member_of then return "a member of " .. res.jump.member_of end
    return nil
end

function M.run()
    local word = vim.fn.expand("<cword>")
    if word == "" or not word:match("^[%a_][%w_]*$") then return end
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    if dotted(line, word_start(line, col)) then return M.search(word, true) end
    require("kotlin-lite.resolve").run(function(ctx, E)
        local why = in_reach(ctx, E)
        if why then
            vim.notify("kotlin-lite: '" .. word .. "' is " .. why .. ", no import needed", vim.log.levels.INFO)
            return
        end
        M.search(word, false)
    end, "auto-import")
end

-- `member`: after a dot, extensions only
function M.search(word, member)
    local buf = vim.api.nvim_get_current_buf()
    local ctx = imports.current()

    if not member then
        if ctx.aliases[word] then
            vim.notify("kotlin-lite: '" .. word .. "' is an import alias", vim.log.levels.INFO)
            return
        end
        if search.decl_in_buffer(word) then
            vim.notify("kotlin-lite: '" .. word .. "' is declared in this file", vim.log.levels.INFO)
            return
        end
    end

    local args = search.decl_args(word)
    for _, p in ipairs(extra_patterns(word)) do vim.list_extend(args, { "-e", p }) end

    search.rg(args, search.search_dirs(), function(items)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local all = M.candidates(items, word)
        if member then
            -- after a dot only extensions need an import; members come with the receiver
            all = vim.tbl_filter(function(c) return c.ext end, all)
        end
        if #all == 0 then
            local what = member and "extension '" .. word .. "'" or "'" .. word .. "'"
            vim.notify("kotlin-lite: no importable declaration of " .. what, vim.log.levels.WARN)
            return
        end

        local seen_by, rest, type_seen = nil, {}, nil
        for _, c in ipairs(all) do
            local v = visible(ctx, c)
            if v then
                seen_by = seen_by or v
                if c.kind == "type" then type_seen = type_seen or v end
            else
                rest[#rest + 1] = c
            end
        end
        -- a visible type is what the name means; another one would shadow it
        if type_seen or #rest == 0 then
            local v = type_seen or seen_by
            local msg = v == "imported" and "already imported"
                or ("needs no import (%s)"):format(v)
            vim.notify("kotlin-lite: '" .. word .. "' " .. msg, vim.log.levels.INFO)
            return
        end
        -- a visible overload may be the one meant: confirm via the picker
        if #rest == 1 and not seen_by then
            M.insert(buf, rest[1].fq)
            return
        end
        vim.ui.select(rest, { prompt = "Import " .. word .. ":", format_item = label }, function(choice)
            if choice and vim.api.nvim_buf_is_valid(buf) then M.insert(buf, choice.fq) end
        end)
    end)
end

return M
