-- What the word under the cursor refers to (gd / K / gri / tagfunc).
-- Buffer-only steps first, then rg over the project + jars in parallel; hits
-- are ranked like the compiler picks: receiver, header, enclosing classes,
-- call shape, platform. Nothing is cached between requests.

local search = require("kotlin-lite.search")
local scope = require("kotlin-lite.scope")
local imports = require("kotlin-lite.imports")
local jars = require("kotlin-lite.jars")
local defs = require("kotlin-lite.defs")
local autoimport = require("kotlin-lite.autoimport")
local reader = require("kotlin-lite.reader")

local M = {}

-- rank penalty for a candidate the context argues against
local DEMOTE = 10

-- lambdas without an implicit receiver
local RECEIVERLESS = {}
for _, n in ipairs({
    "let", "also", "forEach", "forEachIndexed", "map", "mapNotNull", "mapIndexed", "flatMap",
    "filter", "filterNot", "filterIsInstance", "any", "all", "none", "count", "first",
    "firstOrNull", "last", "lastOrNull", "find", "single", "singleOrNull", "sortedBy",
    "sortedByDescending", "groupBy", "associate", "associateBy", "associateWith", "onEach",
    "takeIf", "takeUnless", "takeWhile", "dropWhile", "repeat", "sumOf", "maxByOrNull",
    "minByOrNull", "maxOf", "minOf", "partition", "fold", "reduce", "zip", "lazy", "require",
    "check", "requireNotNull", "checkNotNull", "use", "getOrElse", "getOrPut", "removeIf",
    "distinctBy", "chunked", "windowed", "sortedWith", "compareBy", "thenBy",
}) do
    RECEIVERLESS[n] = true
end

-- words before `(` that are not a callee
local NOT_CALLEE = {
    ["if"] = true, ["when"] = true, ["for"] = true, ["while"] = true, ["catch"] = true,
    ["fun"] = true, ["return"] = true, ["this"] = true, ["super"] = true, ["constructor"] = true,
}

-- words that can't be the type in front of a Java member name
local JAVA_NOT_TYPE = {}
for _, n in ipairs({
    "return", "new", "throw", "else", "case", "yield", "assert", "in", "is", "as", "if",
    "while", "for", "do", "try", "catch", "switch", "synchronized", "throws", "import", "package",
}) do
    JAVA_NOT_TYPE[n] = true
end

local function last_seg(name)
    return name and name:match("([%w_]+)$")
end

local function read_of(E)
    E.read = E.read or reader.new()
    return E.read
end
M.reader_of = read_of

-- the context's own lines (unsaved edits included) for its file
local function lines_for(ctx, E, path, lnum)
    if path == ctx.path then return ctx.sc.lines end
    return read_of(E).lines(path, lnum + 40)
end

-------------------------------------------------------------------
-- symbols (item.sym)
-------------------------------------------------------------------
-- { name, kind = type|fun|prop|entry|param|local, owners (innermost first:
--   { name, kind, text }), pkg, ext, vis, mp = expect|actual (own or owner's),
--   range = { from, to } (params / locals only) }

local VIS = { "private", "protected", "internal", "public" }

local function modifier(text, set)
    for _, w in ipairs(set) do
        if text:find("%f[%w_]" .. w .. "%f[^%w_]") then return w end
    end
    return nil
end

-- `mods`: the text before the name
local function new_sym(word, kind, owners, mods)
    local mp = modifier(mods, { "expect", "actual" })
    for _, o in ipairs(owners) do
        if mp then break end
        mp = modifier((o.text or ""):match("^[^{]*") or "", { "expect", "actual" })
    end
    return {
        name = word, kind = kind, owners = owners,
        vis = modifier(mods, VIS) or "public", mp = mp,
    }
end

-------------------------------------------------------------------
-- cursor context
-------------------------------------------------------------------

-- identifier at or after `col` -> start, word, end (0-based, end exclusive)
local function word_at(line, col)
    for s, w, e in line:gmatch("()([%a_][%w_]*)()") do
        if e - 1 > col then return s - 1, w, e - 1 end
    end
end

-- receiver of `.word` / `?.word` / `::word`, nil without one:
-- { kind = this|super|unknown|chain|call, label?, segs?, lnum?, col?, ctor? }
local function receiver(sc, lnum, s)
    local before = sc.mask[lnum]:sub(1, s)
    local rest = before:match("^(.-)%??%.%s*$")
    if not rest then
        rest = before:match("^(.-)::%s*$")
        if not rest or rest:match("^%s*$") then return nil end -- ::fn
    end
    local l = lnum
    while rest:match("^%s*$") and l > 1 do -- `.word` chained from the line above
        l = l - 1
        rest = sc.mask[l]
    end
    rest = rest:gsub("%s+$", "")
    if rest == "" then return { kind = "unknown" } end

    if rest:sub(-1) == ")" then
        local depth = 0
        for i = #rest, 1, -1 do
            local c = rest:sub(i, i)
            if c == ")" then
                depth = depth + 1
            elseif c == "(" then
                depth = depth - 1
                if depth == 0 then
                    local cs, callee = (rest:sub(1, i - 1):gsub("%s*%b<>%s*$", "")):match("()([%a_][%w_]*)%s*$")
                    if not callee then return { kind = "unknown" } end
                    if callee:match("^%u") then
                        return { kind = "chain", segs = { callee }, ctor = true }
                    end
                    return { kind = "call", lnum = l, col = cs - 1 }
                end
            end
        end
        return { kind = "unknown" }
    end

    local chain = rest:match("([%w_.@]+)$")
    if not chain then return { kind = "unknown" } end
    local label = chain:match("^this@([%w_]+)$")
    if chain == "this" or label then return { kind = "this", label = label } end
    if chain == "super" or chain:match("^super@") then return { kind = "super" } end
    if chain:find("@", 1, true) or chain:find("..", 1, true) or chain:match("^%.") then
        return { kind = "unknown" }
    end
    return { kind = "chain", segs = vim.split(chain, ".", { plain = true }), lnum = l, col = #rest - #chain }
end

-- `word = ...` as a call argument -> { lnum, col } of the callee
local function named_arg(sc, lnum, s, e)
    local m = sc.mask
    local after = m[lnum]:sub(e + 1)
    if not (after:match("^%s*=[^=]") or after:match("^%s*=$")) then return nil end
    local depth, first = 0, true
    local l, i = lnum, s
    while l >= 1 and l > lnum - 200 do
        local line = m[l]
        while i >= 1 do
            local c = line:sub(i, i)
            if c:match("%S") then
                if first then
                    if c ~= "(" and c ~= "," then return nil end
                    first = false
                end
                if c == ")" or c == "]" or c == "}" then
                    depth = depth + 1
                elseif c == "[" or c == "{" then
                    if depth == 0 then return nil end
                    depth = depth - 1
                elseif c == "(" then
                    if depth == 0 then
                        local head = (line:sub(1, i - 1):gsub("%s*%b<>%s*$", ""))
                        local cs, callee = head:match("()([%a_][%w_]*)%s*$")
                        if not callee or NOT_CALLEE[callee] then return nil end
                        return { lnum = l, col = cs - 1 }
                    end
                    depth = depth - 1
                end
            end
            i = i - 1
        end
        l = l - 1
        i = l >= 1 and #m[l] or 0
    end
    return nil
end

-- argument shapes of the call after (lnum, e): lit|lambda|named|other|trailing;
-- nil when not a call
local function call_args(sc, lnum, e)
    local m = sc.mask
    local l, i = lnum, e + 1
    local gen = m[l]:sub(i):match("^%s*%b<>()")
    if gen then i = i + gen - 1 end
    i = i + m[l]:sub(i):match("^%s*()") - 1
    local c = m[l]:sub(i, i)
    if c == "{" then return { "trailing" } end
    if c ~= "(" then return nil end
    local args, depth, buf = {}, 0, {}
    local function push()
        local a = vim.trim(table.concat(buf))
        buf = {}
        if a == "" then return end -- `f()`, or a trailing comma
        if a:match("^\2[\2%s]*$") then -- a masked string / char literal
            args[#args + 1] = "lit"
        elseif a:match("^[%a_][%w_]*%s*=[^=]") then
            args[#args + 1] = "named"
        elseif a:match("^%-?%.?%d") or a == "true" or a == "false" or a == "null" then
            args[#args + 1] = "lit"
        elseif a:match("^{") or a:match("^::") then
            args[#args + 1] = "lambda"
        else
            args[#args + 1] = "other"
        end
    end
    while l <= #m and l <= lnum + 60 do
        local line = m[l]
        while i <= #line do
            local ch = line:sub(i, i)
            if ch == "(" or ch == "[" or ch == "{" then
                depth = depth + 1
                if depth > 1 then buf[#buf + 1] = ch end
            elseif ch == ")" or ch == "]" or ch == "}" then
                depth = depth - 1
                if depth == 0 then
                    push()
                    if line:sub(i + 1):match("^%s*{") then args[#args + 1] = "trailing" end
                    return args
                end
                buf[#buf + 1] = ch
            elseif depth == 1 and ch == "," then
                push()
            elseif depth >= 1 then
                local raw = sc.lines[l]:sub(i, i)
                buf[#buf + 1] = (raw == '"' or raw == "'") and "\2" or ch
            end
            i = i + 1
        end
        buf[#buf + 1] = " "
        l, i = l + 1, 1
    end
    return nil
end

--- Scanned text + header of a file, open in a buffer or not.
function M.base_of(path, lines)
    return {
        path = path,
        sc = scope.scan(lines),
        hdr = imports.parse(vim.list_slice(lines, 1, 200)),
    }
end

function M.base(buf)
    return M.base_of(vim.api.nvim_buf_get_name(buf), vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end

--- Context of the identifier at (lnum, 0-based col).
function M.context_at(base, lnum, col)
    base = base.base or base
    local line = base.sc.lines[lnum] or ""
    local s, word, e = word_at(line, col)
    if not s then return nil end
    local ctx = setmetatable({ lnum = lnum, s = s, e = e, word = word, line = line, base = base },
        { __index = base })
    ctx.pos = scope.key(lnum, s)
    local m = base.sc.mask[lnum] or ""
    ctx.code = m:sub(s + 1, e) == word -- false in a comment / string
    if ctx.code then
        ctx.recv = receiver(base.sc, lnum, s)
        local after = m:sub(e + 1)
        ctx.call = (after:match("^%s*%(") or after:match("^%s*{") or after:match("^%s*%b<>%s*%(")) ~= nil
        ctx.ref = m:sub(1, s):match("::%s*$") ~= nil
        ctx.args = ctx.call and call_args(base.sc, lnum, e) or nil
    end
    return ctx
end

--- Context of a bare name (`:tag Name`): no position.
function M.name_context(base, word)
    base = base.base or base
    return setmetatable({ word = word, line = "", base = base }, { __index = base })
end

-------------------------------------------------------------------
-- buffer lookups
-------------------------------------------------------------------

local function is_local(sc, d)
    return d.kind == "param" or d.kind == "lambda"
        or (not d.member_of and d.scope ~= sc.root and d.scope.kind ~= "type")
end

local function buffer_sym(ctx, d, word)
    local kind
    if d.kind == "param" or d.kind == "lambda" then
        kind = "param"
    elseif is_local(ctx.sc, d) then
        kind = "local"
    else
        kind = d.kind == "val" and "prop" or d.kind
    end
    local owners = {}
    local b = d.member_of
    while b and b ~= ctx.sc.root do
        if b.kind == "type" then
            local text = vim.trim((b.head:gsub("%s+", " ")))
            local h = autoimport.header_of(text)
            owners[#owners + 1] = { name = b.name, kind = h and h.kind or "class", text = text }
        end
        b = b.parent
    end
    local sym = new_sym(word, kind, owners, (ctx.sc.mask[d.lnum] or ""):sub(1, d.col))
    sym.pkg = ctx.hdr.package
    if kind == "param" or kind == "local" then sym.range = { from = d.from, to = d.to } end
    return sym
end

local function here_item(ctx, d)
    local word = ctx.sc.lines[d.lnum]:match("^[%w_]+", d.col + 1) or ctx.word
    return {
        filename = ctx.path,
        lnum = d.lnum,
        col = d.col + 1,
        text = vim.trim(ctx.sc.lines[d.lnum] or ""),
        sym = buffer_sym(ctx, d, word),
    }
end

-- declared or constructed type of variable `name`
local function type_of_decl(sc, d, name)
    local after = sc.mask[d.lnum]:sub(d.col + #name + 1)
    local t = after:match("^%s*:%s*([%w_.]+)")
    if t then return last_seg(t) end
    local init = after:match("^%s*=%s*(.*)$") or after:match("^%s*by%s+(.*)$") or ""
    init = init:match("^lazy%s*{%s*(.*)$") or init:match("^remember%s*%b()%s*{%s*(.*)$")
        or init:match("^remember%s*{%s*(.*)$") or init
    t = last_seg(init:match("^([%w_.]+)%s*%(") or init:match("^([%w_.]+)%s*%b<>%s*%("))
    return t and t:match("^%u") and t or nil
end

local function local_decl(ctx, name, lnum, col)
    local p = scope.key(lnum, col)
    return scope.visible(scope.decls(ctx.sc, name), p, p)
end

-- types an unqualified name reaches; `open` when a lambda may add a receiver
local function implicit_receivers(ctx)
    local set, open, lambdas = {}, false, {}
    for _, b in ipairs(scope.enclosing(ctx.sc, ctx.pos)) do
        if b.kind == "type" then
            if b.name then set[b.name] = true end
            for _, s in ipairs(b.supers or {}) do set[last_seg(s)] = true end
        elseif b.kind == "fun" and b.ext then
            set[b.ext] = true
        elseif b.kind == "lambda" and not RECEIVERLESS[b.callee or ""] then
            open = true
            lambdas[#lambdas + 1] = b
        end
    end
    -- an expression-bodied extension fun on this very line
    local sig = ctx.sc.mask[ctx.lnum]:sub(1, ctx.s):match("%f[%w_]fun%s+(.-)%s*%(")
    local recv = sig and (sig:gsub("^%b<>%s*", "")):match("^(.-)%.[%w_]+$")
    if recv then set[(recv:gsub("%b<>", "")):match("([%w_]+)%??$")] = true end
    return set, open, lambdas
end

-------------------------------------------------------------------
-- classifying rg hits
-------------------------------------------------------------------

-- -> kind, extension receiver, self (the header on this line owns it)
local function kotlin_kind(s, w)
    local pw = vim.pesc(w)
    local stripped = s:gsub("::%s*class", "")
    for _, kw in ipairs({ "class", "interface", "object", "typealias" }) do
        if stripped:find("%f[%w_]" .. kw .. "%s+" .. pw .. "%f[^%w_]") then return "type" end
    end
    if s:find("%f[%w_]enum%s+class%s+[%w_]+[^{]*{[^}]*%f[%w_]" .. pw .. "%f[^%w_]") then
        return "entry", nil, true
    end
    local h = s:match("%f[%w_]fun%s+(.*)$")
    if h then
        local head = (h:gsub("^%b<>%s*", "")):match("^(.-)%s*%(")
        if head and head:match("([%w_]+)$") == w then return "fun", head:match("^(.-)%.[%w_]+$") end
    end
    local i = 1
    while true do
        local _, b = s:find("%f[%w_]va[lr]%s+", i)
        if not b then break end
        local rest = (s:sub(b + 1):gsub("^%b<>%s*", ""))
        local head = rest:match("^([%w_.<>?, ]-)%s*[:=]") or rest:match("^([%w_.<>?, ]-)%s+by%f[^%w_]")
            or rest:match("^([%w_.<>?, ]-)%s*[,)]") or rest:match("^([%w_.<>?, ]-)%s*$")
        if head and head:match("([%w_]+)$") == w then return "prop", head:match("^(.-)%.[%w_]+$") end
        i = b + 1
    end
    if s:match("^" .. pw .. "%s*[(,;{]") or s:match("^" .. pw .. "%s*$") then return "entry" end
    return nil
end

local function java_kind(s, w)
    local pw = vim.pesc(w)
    for _, kw in ipairs({ "class", "interface", "enum", "record" }) do
        if s:find("%f[%w_]" .. kw .. "%s+" .. pw .. "%f[^%w_]") then return "type" end
    end
    if s:find("%f[%w_]enum%s+[%w_]+[^{]*{[^}]*%f[%w_]" .. pw .. "%f[^%w_]") then return "entry", nil, true end
    if s:match("^" .. pw .. "%s*[(,;{]") or s:match("^" .. pw .. "%s*$") then return "entry" end
    local pre, sep = s:match("^(.-)%f[%w_]" .. pw .. "%f[^%w_]%s*([(=;,])")
    if not pre or pre:find("=", 1, true) then return nil end
    local _, open = pre:gsub("%(", "")
    local _, close = pre:gsub("%)", "")
    if open > close then return nil end -- a parameter / argument
    local tok = pre:match("([%w_<>%[%]?.,]+)%s+$")
    local first = pre:match("^%s*([%w_]+)")
    if not tok or JAVA_NOT_TYPE[tok] or (first and JAVA_NOT_TYPE[first]) then return nil end
    return sep == "(" and "fun" or "prop"
end

--- What rg hit `it` declares as `word` -> { kind, chain, ext, col }, or nil
--- (comment, local, plain statement).
local function classify(it, word, read)
    local text = it.text
    if search.is_comment_text(text) then return nil end
    local wpos = text:find("%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]")
    if not wpos then return nil end
    local pre = text:sub(1, wpos - 1)
    if pre:find("//", 1, true) or pre:find("/*", 1, true) then return nil end

    local java = it.filename:sub(-5) == ".java"
    local kind, ext, self
    if java then
        kind, ext, self = java_kind(text, word)
    else
        kind, ext, self = kotlin_kind(text, word)
    end
    if not kind then return nil end

    local chain = {}
    if (it.indent or 0) > 0 then
        chain = autoimport.owners(read.lines(it.filename, it.lnum), it.lnum)
        if not chain then return nil end -- inside a fun / init / lambda
    end
    -- owned by the header on this line: one-line enum / object, ctor property
    local h = (self or kind == "prop" or kind == "fun") and autoimport.header_of(text)
    if h and h.name ~= word and (self or kind == "prop" or text:find("{.*%f[%w_]fun%f[^%w_]")) then
        h.text = text
        table.insert(chain, 1, h)
    end
    if kind == "entry" and (not chain[1] or chain[1].kind ~= "enum") then return nil end
    return {
        kind = kind,
        chain = chain,
        ext = ext and (ext:gsub("%b<>", "")):match("([%w_]+)%??$"),
        col = (it.indent or 0) + wpos,
    }
end

-- member, companion member or extension of a `set` type
local function owned_by(c, set)
    local o = c.chain[1]
    if not o then return c.ext ~= nil and set[c.ext] == true end
    if set[o.name] then return true end
    local outer = c.chain[2]
    return outer ~= nil and set[outer.name] == true
        and (o.text or ""):find("%f[%w_]companion%f[^%w_]") ~= nil
end

-------------------------------------------------------------------
-- supertypes of a receiver type
-------------------------------------------------------------------

local function header_args(names)
    return { "-e", [=[\b(class|interface|object|enum|record)\s+(]=] .. table.concat(names, "|") .. [=[)\b]=] }
end

local function java_supers(text)
    local out = {}
    local s = text:gsub("%b<>", "")
    for _, kw in ipairs({ "extends", "implements" }) do
        local list = s:match("%f[%w_]" .. kw .. "%s+([%w_.,%s]+)")
        for n in (list or ""):gmatch("[%w_.]+") do
            if n ~= "extends" and n ~= "implements" then out[#out + 1] = last_seg(n) end
        end
    end
    return out
end

local function supers_from(items, set, read)
    local impl = require("kotlin-lite.impl")
    local out = {}
    for _, it in ipairs(items) do
        local h = not search.is_comment_text(it.text) and autoimport.header_of(it.text)
        if h and set[h.name] then
            local text = impl.header_text(read.lines(it.filename, it.lnum + 30), it.lnum)
            local supers
            if it.filename:sub(-5) == ".java" then
                supers = java_supers(text)
            else
                local parsed = impl.parse_header(text)
                supers = vim.tbl_map(last_seg, parsed and parsed.supers or {})
            end
            vim.list_extend(out, supers)
        end
    end
    return out
end

-------------------------------------------------------------------
-- project search
-------------------------------------------------------------------

local function project_args(ctx, word, opts)
    local w = word
    local args = search.decl_args(w)
    vim.list_extend(args, {
        "-e", [=[\b(enum|record)\s+]=] .. w .. [=[\b]=],
        -- java member (a `>` not of a kotlin `->`)
        "-e", [=[([\w\]]|[^-]>)\s+]=] .. w .. [=[\s*[(=;,]]=],
    })
    -- enum entries only where one can be meant: each hit costs a read
    if w:match("^%u") and (opts.levels or ctx.hdr.explicit[w] or w:match("^%u[%u%d_]*$")) then
        vim.list_extend(args, {
            "-e", [=[^\s+]=] .. w .. [=[\s*([({,;]|$)]=],
            "-e", [=[\benum\s+(class\s+)?\w+[^{]*\{[^}]*\b]=] .. w .. [=[\b]=],
        })
    end
    return args
end

-- hits whose package + owners are the qualifier, else in its package
local function in_qualifier(cands, qualifier)
    local exact = vim.tbl_filter(function(c)
        local parts = { c.pkg }
        for i = #c.chain, 1, -1 do parts[#parts + 1] = c.chain[i].name end
        return c.pkg ~= nil and table.concat(parts, ".") == qualifier
    end, cands)
    if #exact > 0 then return exact end
    local best_len, keep = -1, {}
    for _, c in ipairs(cands) do
        local pkg = c.pkg
        if pkg and imports.within(pkg, qualifier) then
            if #pkg > best_len then best_len, keep = #pkg, {} end
            if #pkg == best_len then keep[#keep + 1] = c end
        end
    end
    return keep
end

local function owner_files(hits, set)
    local files = {}
    for _, it in ipairs(hits) do
        local h = not search.is_comment_text(it.text) and autoimport.header_of(it.text)
        if h and set[h.name] then files[it.filename] = true end
    end
    return files
end

-- files read for member hits before giving up (they're mostly locals)
local READ_BUDGET = 300

-- hits classified on demand: top-level ones from their text, members cost a
-- file read, so only files that can hold the member are read first
local function new_pool(hits, word, read)
    for _, it in ipairs(hits) do
        if (it.indent or 0) > 0 then
            read.need[it.filename] = math.max(read.need[it.filename] or 0, it.lnum)
        end
    end
    local P = { cands = {}, read = read }
    local done = {}

    local function take_one(i, it)
        done[i] = true
        local c = classify(it, word, P.read)
        if c then
            c.item = it
            it.col = c.col
            it.member, it.ext = c.chain[1] ~= nil, c.ext
            it.pkg = P.read.package(it.filename)
            c.pkg = it.pkg
            local owners = vim.tbl_map(function(o)
                return { name = o.name, kind = o.kind, text = o.text }
            end, c.chain)
            it.sym = new_sym(word, c.kind, owners, it.text:sub(1, c.col - (it.indent or 0) - 1))
            it.sym.pkg, it.sym.ext = it.pkg, c.ext
            P.cands[#P.cands + 1] = c
        end
    end

    function P.take(pred)
        for i, it in ipairs(hits) do
            if not done[i] and pred(it) then take_one(i, it) end
        end
    end

    --- the rest: top level, project members, jar members (READ_BUDGET files)
    function P.take_all()
        P.take(function(it) return (it.indent or 0) == 0 end)
        local budget = READ_BUDGET
        for _, jar in ipairs({ false, true }) do
            for i, it in ipairs(hits) do
                if not done[i] and jars.is_jar(it.filename) == jar then
                    local fresh = not P.read.has(it.filename)
                    if not fresh or budget > 0 then
                        if fresh then budget = budget - 1 end
                        take_one(i, it)
                    end
                end
            end
        end
    end
    return P
end

-- members of the receiver types, level by level, then (`expand`) of their
-- supertypes; `headers(names)` = rg hits of those types' headers
local function by_owner(pool, levels, headers, expand)
    local seen, level, li = {}, levels[1], 1
    for _ = 1, 6 do
        local set, names = {}, {}
        for _, n in ipairs(level or {}) do
            if n and not seen[n] then
                seen[n], set[n] = true, true
                names[#names + 1] = n
            end
        end
        if #names == 0 then return nil end
        local hits = headers(names)
        local files = owner_files(hits, set)
        pool.take(function(it) return (it.indent or 0) == 0 or files[it.filename] end)
        local keep = vim.tbl_filter(function(c) return owned_by(c, set) end, pool.cands)
        if #keep > 0 then return keep end
        li = li + 1
        if levels[li] then
            level = levels[li]
        elseif expand then
            level = supers_from(hits, set, pool.read)
        else
            return nil
        end
    end
    return nil
end

-- common|jvm|<source set>, nil without a file
local function platform(path)
    if path == "" then return nil end
    local sset = defs._source_set(path)
    if not sset then return "jvm" end
    if sset:match("^common") then return "common" end
    if sset:match("^jvm") or sset:match("^android") or sset:match("^desktop") then return "jvm" end
    return sset
end

-- of equally ranked jar decls, the one this file compiles against: the
-- `expect` from common code, else the jvm / android `actual`
local function by_platform(ctx, items, best)
    local want = platform(ctx.path or "")
    if not want then return nil end
    local pick
    for _, it in ipairs(items) do
        if it.rank == best then
            if not jars.is_jar(it.filename) then return nil end
            local d = defs.describe(it)
            local ok
            if want == "common" then
                ok = d.mp == "expect"
            elseif want == "jvm" then
                ok = d.mp == "actual" and d.sset ~= nil
                    and (d.sset:match("^jvm") or d.sset:match("^android")) ~= nil
            end
            if ok then
                if pick then return nil end
                pick = it
            end
        end
    end
    return pick
end

--- Params of the fun at (lnum, col) -> { name, lnum, s, e } (first line of each)
function M.param_spans(lines, lnum, col)
    local m = scope.mask(vim.list_slice(lines, lnum, lnum + 30))
    local out, depth, cur, pending = {}, 0, nil, false
    local function finish(l, e)
        if cur then
            local stop = cur.l == l and e or #m[cur.l]
            local text = lines[lnum + cur.l - 1]:sub(cur.s + 1, stop):gsub("%s+$", "")
            local flat = m[cur.l]:sub(cur.s + 1, stop):gsub("%b()", ""):gsub("%b<>", "")
            out[#out + 1] = {
                name = flat:match("([%w_]+)%s*:") or flat:match("([%w_]+)%s*$"),
                lnum = lnum + cur.l - 1, s = cur.s, e = cur.s + #text,
            }
        end
        cur, pending = nil, false
    end
    for l, line in ipairs(m) do
        for i = l == 1 and col + 1 or 1, #line do
            local c = line:sub(i, i)
            if pending and not cur and c:match("%S") and c ~= ")" then cur = { l = l, s = i - 1 } end
            if c == "(" or c == "[" or c == "{" or c == "<" then
                depth = depth + 1
                if depth == 1 then pending = c == "(" end
            elseif c == ")" or c == "]" or c == "}" or (c == ">" and line:sub(i - 1, i - 1) ~= "-") then
                if depth == 1 and c == ")" then
                    finish(l, i - 1)
                    return out
                end
                depth = depth - 1
            elseif c == "," and depth == 1 then
                finish(l, i - 1)
                pending = true
            end
        end
    end
    return out
end

--- The call around (or at the callee) (lnum, col) -> { ctx (callee), index, name? }
function M.call_at(base, lnum, col)
    local sc = base.sc
    local here = M.context_at(base, lnum, col)
    if here and here.code and here.call and here.s <= col and col < here.e then
        return { ctx = here, index = 0 }
    end
    local p = scope.key(lnum, col)
    local groups = vim.tbl_filter(function(g) return g.open < p and p <= g.close end, sc.parens)
    table.sort(groups, function(a, b) return a.open > b.open end)
    for _, g in ipairs(groups) do
        local gl, gc = scope.unkey(g.open)
        local head = (sc.mask[gl]:sub(1, gc):gsub("%s*%b<>%s*$", ""))
        local cs, callee = head:match("()([%a_][%w_]*)%s*$")
        if callee and not NOT_CALLEE[callee] then
            local index, depth, arg = 0, 0, {}
            for l = gl, lnum do
                local line = sc.mask[l]
                local from, to = l == gl and gc + 2 or 1, l == lnum and col or #line
                for i = from, to do
                    local c = line:sub(i, i)
                    if c:match("[%(%[{]") then
                        depth = depth + 1
                    elseif c:match("[%)%]}]") then
                        depth = depth - 1
                    elseif c == "," and depth == 0 then
                        index, arg = index + 1, {}
                    elseif depth == 0 then
                        arg[#arg + 1] = c
                    end
                end
                arg[#arg + 1] = " "
            end
            local name = table.concat(arg):match("^%s*([%a_][%w_]*)%s*=[^=]")
            return { ctx = M.context_at(base, gl, cs - 1), index = index, name = name }
        end
    end
    return nil
end

-- params of the fun declared at (lnum, col) -> { default, vararg, fn, lambda_ok }
local function decl_params(lines, lnum, col)
    local text = table.concat(scope.mask(vim.list_slice(lines, lnum, lnum + 30)), "\n")
    local open = text:find("(", col + 1, true)
    local group = open and text:match("^%b()", open)
    if not group then return nil end
    local parts, depth, buf = {}, 0, {}
    for ch in group:sub(2, -2):gsub("%->", "\1"):gmatch(".") do
        if ch:match("[(<%[{]") then
            depth = depth + 1
        elseif ch:match("[)>%]}]") then
            depth = depth - 1
        end
        if ch == "," and depth == 0 then
            parts[#parts + 1] = table.concat(buf)
            buf = {}
        else
            buf[#buf + 1] = ch
        end
    end
    parts[#parts + 1] = table.concat(buf)
    local params = {}
    for _, p in ipairs(parts) do
        if p:match("%S") then
            local flat = p:gsub("%b()", "()"):gsub("%b<>", "")
            local ty = flat:match(":(.*)$") or flat -- java: no colon, the type comes first
            ty = vim.trim((ty:gsub("=.*$", "")))
            params[#params + 1] = {
                vararg = flat:find("%f[%w_]vararg%f[^%w_]") ~= nil or flat:find("...", 1, true) ~= nil,
                default = flat:find("=", 1, true) ~= nil,
                fn = ty:find("\1", 1, true) ~= nil,
                lambda_ok = ty:find("\1", 1, true) ~= nil or ty:match("^%u%??$") ~= nil
                    or ty:match("^Any%??$") ~= nil or ty:match("^K?Function") ~= nil
                    or ty:match("^[%w_.]*Function%d*") ~= nil,
            }
        end
    end
    return params
end

-- can a fun with `params` take `args`? (count, defaults, vararg, literal for a fn)
local function fits(params, args)
    local min, max, named = 0, 0, 0
    for _, p in ipairs(params) do
        if p.vararg then
            max = math.huge
        else
            max = max + 1
            if not p.default then min = min + 1 end
        end
    end
    for _, a in ipairs(args) do
        if a == "named" then named = named + 1 end
    end
    if #args > max or #args < min - (named > 0 and #params or 0) then return false end
    if args[#args] == "trailing" and not (params[#params] and params[#params].lambda_ok) then
        return false
    end
    for i, a in ipairs(args) do
        if a == "named" or a == "trailing" then break end -- positions unknown from here on
        local p = params[i]
        if p and p.vararg then break end
        if p and a == "lit" and p.fn then return false end
    end
    return true
end

local function result(items, decisive, word)
    if #items == 1 then return { jump = items[1], sole = true } end
    local best = math.huge
    for _, it in ipairs(items) do best = math.min(best, it.rank) end
    local top = vim.tbl_filter(function(it) return it.rank == best end, items)
    if #top == 1 and decisive(best) then return { jump = top[1] } end
    return { pool = items, word = word }
end

-- set item.rank and pick; o.filtered = already narrowed by the receiver
local function finish(ctx, word, cands, o, read)
    if o.kind then cands = vim.tbl_filter(function(c) return c.kind == o.kind end, cands) end
    if #cands == 0 then return { err = "no declaration found for '" .. word .. "'" } end
    for _, hint in ipairs({ o.pkg or false, o.soft_qualifier or false }) do
        if hint then
            local keep = vim.tbl_filter(function(c) return c.pkg == hint end, cands)
            if #keep > 0 then cands, o.filtered = keep, true end
        end
    end

    local explicit = ctx.hdr.explicit[word] ~= nil
    local demoted = false
    for _, c in ipairs(cands) do
        local top = c.chain[#c.chain]
        -- a member ranks by its outermost class, unless the name is imported
        local r = imports.rank(ctx.hdr, (top and not explicit) and top.name or word, c.pkg)
        local demote = false
        if o.implicit and not o.open and c.chain[1] and not explicit and not owned_by(c, o.implicit) then
            demote = true -- unqualified name, member of an unrelated class
        end
        if ctx.code and not o.no_shape then
            if ctx.call and (c.kind == "prop" or c.kind == "entry") then demote = true end
            if not ctx.call and not ctx.ref and c.kind == "fun" then demote = true end
        end
        if not demote and ctx.args and c.kind == "fun" and read then
            -- signature from the rg line, from the file when it spans lines
            local it = c.item
            local at = c.col - (it.indent or 0) -- name position in it.text
            local open = it.text:find("(", at, true)
            local params = open and it.text:match("^%b()", open) and decl_params({ it.text }, 1, at - 1)
                or decl_params(read.lines(it.filename, it.lnum + 30), it.lnum, c.col - 1)
            if params and not fits(params, ctx.args) then demote = true end
        end
        if demote then demoted = true end
        c.item.rank = r + (demote and DEMOTE or 0)
        -- `import pkg.Owner.*`
        if c.chain[1] and c.pkg then
            local owner = c.pkg .. "." .. c.chain[1].name
            for _, w in ipairs(ctx.hdr.wildcards) do
                if w == owner then c.item.imported = true end
            end
        end
    end

    local items = defs.latest_only(vim.tbl_map(function(c) return c.item end, cands))
    local best = math.huge
    for _, it in ipairs(items) do best = math.min(best, it.rank) end
    if best % DEMOTE >= imports.NONE and not o.filtered then
        -- nothing ranks: project over jars
        local own = vim.tbl_filter(function(it) return not jars.is_jar(it.filename) end, items)
        if #own > 0 then items = own end
    end
    local pick = by_platform(ctx, items, best)
    if pick then return { jump = pick } end
    return result(items, function(b)
        return o.filtered or b % DEMOTE < imports.NONE or (b < DEMOTE and demoted)
    end, word)
end

-- a.b.Outer -> "a/b"
local function pkg_dir(qualifier)
    local segs = {}
    for seg in (qualifier or ""):gmatch("[^.]+") do
        if seg:match("^%u") then break end
        segs[#segs + 1] = seg
    end
    return #segs > 0 and table.concat(segs, "/") or nil
end

local function keys(set)
    local out = {}
    for k in pairs(set or {}) do out[#out + 1] = k end
    table.sort(out)
    return out
end

-- `final` = false: project hits only; nil unless jars can't change the answer
local function decide(ctx, word, opts, hits, read, headers, final)
    local implicit = opts.implicit and keys(opts.implicit) or {}
    local pool = new_pool(hits, word, read)

    if opts.qualifier then
        pool.take(function(it)
            local pkg = read.package(it.filename)
            return pkg ~= nil and imports.within(pkg, opts.qualifier)
        end)
        local cands = in_qualifier(pool.cands, opts.qualifier)
        if #cands == 0 then
            return final and { err = ("no declaration of '%s' in %s"):format(word, opts.qualifier) } or nil
        end
        return finish(ctx, word, cands, { filtered = true, no_shape = opts.import_line, kind = opts.kind }, read)
    end

    local o = { pkg = opts.pkg, soft_qualifier = opts.soft_qualifier, kind = opts.kind }
    if opts.levels or #implicit > 0 then
        -- receiver types (or implicit ones) before anything top level
        local keep = by_owner(pool, opts.levels or { implicit }, headers, opts.levels ~= nil)
        if keep then
            for _, c in ipairs(keep) do c.item.member_of = c.chain[1] and c.chain[1].name or c.ext end
            o.filtered = true
            return finish(ctx, word, keep, o, read)
        end
        if opts.strict then
            return final and { err = "no member '" .. word .. "' found in " .. table.concat(opts.levels[1], ", ") } or nil
        end
    end
    if opts.implicit and not opts.open then
        -- unqualified: not a member of an unrelated class; the header decides
        local q = ctx.hdr.explicit[word]
        pool.take(function(it)
            if (it.indent or 0) == 0 then return true end
            local pkg = q and read.package(it.filename)
            return pkg ~= nil and imports.within(pkg, q)
        end)
        local res = finish(ctx, word, pool.cands, vim.deepcopy(o), read)
        local r = res.jump and res.jump.rank % DEMOTE
        if r and (r <= 2 or (final and r < imports.NONE)) then return res end
    end
    if not final then return nil end
    pool.take_all()
    o.implicit, o.open = opts.implicit, opts.open
    return finish(ctx, word, pool.cands, o, read)
end

-- one search per args + dirs per request
local function start(E, args, dirs)
    E.memo = E.memo or {}
    local k = table.concat(args, "\0") .. "\0\0" .. table.concat(dirs, "\0")
    local h = E.memo[k]
    if not h or h.cancelled then
        h = E.start(args, dirs)
        E.memo[k] = h
    end
    return h
end

--- Declarations of `word` in project + jars, narrowed and ranked. Project and
--- jars are searched in parallel; the jar search is dropped when the project
--- settles it.
--- opts: qualifier (strict package), levels (receiver types; strict: only
--- them), pkg / soft_qualifier (preferred), implicit / open (unqualified name)
local function project(ctx, word, opts, E)
    if opts.pkg_dir then
        -- known package: its directory first
        local narrowed = vim.tbl_extend("force", opts, { pkg_dir = false, glob = opts.pkg_dir })
        local res = project(ctx, word, narrowed, E)
        if not res.err then return res end
        opts = vim.tbl_extend("force", opts, { pkg_dir = false })
    end
    local owners = opts.levels and opts.levels[1] or keys(opts.implicit)
    local function headers(names)
        return E.await(start(E, header_args(names), search.search_dirs()))
    end
    if #owners > 0 then start(E, header_args(owners), search.search_dirs()) end

    local args = project_args(ctx, word, opts)
    if opts.glob then args = vim.list_extend({ "-g", "**/" .. opts.glob .. "/*" }, args) end
    local jar_dirs = jars.jar_dirs()
    local hp = start(E, args, { search.root() })
    local hj = #jar_dirs > 0 and start(E, args, jar_dirs) or nil
    local read = read_of(E)

    local hits = E.await(hp)
    if hj then
        local res = not hj.items and decide(ctx, word, opts, hits, read, headers, false)
        if res then
            hj.cancelled = true
            E.cancel(hj)
            return res
        end
        hits = vim.list_extend(vim.list_slice(hits), E.await(hj))
    end
    return decide(ctx, word, opts, hits, read, headers, true)
end

-------------------------------------------------------------------
-- named arguments
-------------------------------------------------------------------

local function param_in(lines, lnum, col, name)
    local m = scope.mask(vim.list_slice(lines, lnum, lnum + 40))
    local depth, started = 0, false
    for li, code in ipairs(m) do
        local i = li == 1 and col + 1 or 1
        while i <= #code do
            local c = code:sub(i, i)
            if c == "(" then
                depth, started = depth + 1, true
            elseif c == ")" then
                depth = depth - 1
                if started and depth == 0 then return nil end
            elseif not started and (c == "{" or c == "=") then
                return nil
            elseif depth == 1 and c:match("[%a_]") then
                local id = code:match("^[%w_]+", i)
                if id == name and code:sub(i + #id):match("^%s*:") then
                    return { lnum = lnum + li - 1, col = i - 1 }
                end
                i = i + #id - 1
            end
            i = i + 1
        end
    end
    return nil
end

-- named arguments of the call at callee (lnum, col)
local function call_arg_names(sc, lnum, col)
    local names, depth = {}, 0
    for l = lnum, math.min(#sc.mask, lnum + 60) do
        local m = sc.mask[l]
        local i = l == lnum and col + 1 or 1
        while i <= #m do
            local c = m:sub(i, i)
            if c == "(" or c == "[" or c == "{" then
                depth = depth + 1
            elseif c == ")" or c == "]" or c == "}" then
                depth = depth - 1
                if depth == 0 then return names end
            elseif depth == 1 and c:match("[%a_]") then
                local id = m:match("^[%w_]+", i)
                local prev = m:sub(1, i - 1):match("(%S)%s*$") or (l > lnum and "," or "")
                if (prev == "(" or prev == ",") and m:sub(i + #id):match("^%s*=[^=]") then
                    names[#names + 1] = id
                end
                i = i + #id - 1
            end
            i = i + 1
        end
    end
    return names
end

local function named_param(ctx, na, E)
    local cctx = M.context_at(ctx, na.lnum, na.col)
    if not cctx then return nil end
    local res = M.resolve(cctx, E)
    local decls = res.jump and { res.jump } or res.pool
    if not decls then return nil end
    if res.pool then -- the best-ranked overloads
        local best = math.huge
        for _, d in ipairs(decls) do best = math.min(best, d.rank or 0) end
        decls = vim.tbl_filter(function(d) return (d.rank or 0) == best end, decls)
    end
    local names = call_arg_names(ctx.sc, na.lnum, na.col)
    local out, partial = {}, {}
    for _, d in ipairs(decls) do
        local lines = lines_for(ctx, E, d.filename, d.lnum)
        local p = param_in(lines, d.lnum, (d.col or 1) - 1, ctx.word)
        if p then
            local item = {
                filename = d.filename, lnum = p.lnum, col = p.col + 1,
                text = vim.trim(lines[p.lnum]), rank = d.rank or 0,
                sym = new_sym(ctx.word, "param", {}, ""),
            }
            item.sym.pkg = d.sym and d.sym.pkg
            local all = true
            for _, n in ipairs(names) do
                if n ~= ctx.word and not param_in(lines, d.lnum, (d.col or 1) - 1, n) then
                    all = false
                    break
                end
            end
            table.insert(all and out or partial, item)
        end
    end
    if #out == 0 then out = partial end
    if #out == 0 then return nil end
    return #out == 1 and { jump = out[1] } or { pool = out, word = ctx.word }
end

-------------------------------------------------------------------
-- receivers
-------------------------------------------------------------------

-- receiver -> project opts; {} when unknown
local function receiver_opts(ctx, r)
    if r.kind == "this" or r.kind == "super" then
        for _, b in ipairs(scope.enclosing(ctx.sc, ctx.pos)) do
            if b.kind == "type" and b.name and (not r.label or b.name == r.label) then
                local supers = vim.tbl_map(last_seg, b.supers or {})
                if r.kind == "super" then return { levels = { supers } } end
                return { levels = { { b.name }, supers } }
            elseif b.kind == "fun" and b.ext and not r.label and r.kind == "this" then
                return { levels = { { b.ext } } }
            end
        end
        return {}
    end
    if r.kind ~= "chain" then return {} end

    local segs = r.segs
    if r.ctor then return { levels = { { segs[1] } } } end
    if #segs == 1 then
        local x = segs[1]
        local d = local_decl(ctx, x, r.lnum, r.col)
        if d then
            local t = type_of_decl(ctx.sc, d, x)
            return t and { levels = { { t } } } or {}
        end
        if x:match("^%u") then return { levels = { { x } } } end
        return { soft_qualifier = x }
    end
    local k
    for i = #segs, 1, -1 do
        if segs[i]:match("^%u") then k = i break end
    end
    if k == #segs then
        local pkg
        if k > 1 and not segs[k - 1]:match("^%u") then pkg = table.concat(segs, ".", 1, k - 1) end
        return { levels = { { segs[k] } }, pkg = pkg }
    end
    if not k and not local_decl(ctx, segs[1], r.lnum, r.col) then
        return { soft_qualifier = table.concat(segs, ".") }
    end
    return {}
end

-------------------------------------------------------------------
-- types
-------------------------------------------------------------------

-- nested resolutions a type lookup may take
local MAX_DEPTH = 4

local function literal_type(s)
    local c = s:sub(1, 1)
    if c == '"' then return "String" end
    if c == "'" then return "Char" end
    local w = s:match("^[%w_.]+") or ""
    if w == "true" or w == "false" then return "Boolean" end
    if not w:match("^%.?%d") then return nil end
    if w:match("^0[xXbB]") then return w:match("[lL]$") and "Long" or "Int" end
    if w:match("[uU][lL]?$") then return w:match("[lL]$") and "ULong" or "UInt" end
    if w:match("[lL]$") then return "Long" end
    if w:match("[fF]$") then return "Float" end
    if w:find("[.eE]") then return "Double" end
    return "Int"
end

-- `a.b.Foo<X>?` -> { name = "Foo", qual = "a.b" }; nil for a function type
local function parse_type(s)
    local t = s:match("^%s*([%a_][%w_.]*)")
    if not t then return nil end
    local qual, name = t:match("^(.*)%.([%w_]+)$")
    return { name = name or t, qual = qual }
end

-- last identifier of the chain `a.b(x).c<T>()!!` at (l, c) -> { lnum, col, word, call }
local function chain_end(m, l, c)
    local line, i = m[l] or "", c + 1
    local last
    while true do
        local s, id = line:match("^%s*()([%a_][%w_]*)", i)
        if not s then break end
        i = s + #id
        last = { lnum = l, col = s - 1, word = id }
        i = line:match("^%b<>()", i) or i
        local p = line:match("^%s*%b()()", i)
        last.call = p ~= nil
        i = p or i
        i = line:match("^!!()", i) or i
        local dot = line:match("^%s*%??%.()", i)
        if not dot then break end
        i = dot
    end
    return last, n
end

local function pos_in(text, idx)
    local l, start = 1, 1
    for nl in text:sub(1, idx - 1):gmatch("()\n") do
        l, start = l + 1, nl + 1
    end
    return l, idx - start
end

-- where the type of `it` comes from: { name, qual?, path } | { self = item }
-- (a type) | { expr = { lnum, col }, path } (a value to resolve)
local function type_source(ctx, E, it)
    local s = it.sym
    if s.kind == "type" then return { self = it } end
    if s.kind == "entry" then return s.owners[1] and { name = s.owners[1].name, path = it.filename } end
    local lines = vim.list_slice(lines_for(ctx, E, it.filename, it.lnum), it.lnum, it.lnum + 30)
    local m = scope.mask(lines)
    local col = (it.col or 1) - 1
    if it.filename:sub(-5) == ".java" then
        local t = (m[1]:sub(1, col):gsub("%b<>", "")):match("([%w_.]+)%s*$")
        return t and vim.tbl_extend("force", parse_type(t), { path = it.filename })
    end
    local text = table.concat(m, "\n")
    local i = col + #s.name + 1
    if s.kind == "fun" then
        local open = text:find("(", i, true)
        local group = open and text:match("^%b()", open)
        if not group then return nil end
        i = open + #group
    end
    local typed = text:match("^%s*:%s*()", i)
    if typed then
        local t = parse_type(text:sub(typed))
        return t and vim.tbl_extend("force", t, { path = it.filename })
    end
    local v = text:match("^%s*=%s*()", i) or text:match("^%s*by%s+lazy%s*{%s*()", i)
        or text:match("^%s*by%s+remember%s*%b()%s*{%s*()", i) or text:match("^%s*by%s+remember%s*{%s*()", i)
    if not v then return nil end
    local l, c = pos_in(text, v)
    local lit = literal_type(lines[l]:sub(c + 1))
    if lit then return { name = lit, path = it.filename } end
    local last = chain_end(m, l, c)
    if not last then return nil end
    if last.call and last.word:match("^%u") then
        return { name = last.word, path = it.filename } -- a constructor
    end
    return { expr = { lnum = it.lnum + l - 1, col = last.col }, path = it.filename }
end

local function base_for(ctx, E, path)
    if path == ctx.path then return ctx.base or ctx end
    E.bases = E.bases or {}
    if not E.bases[path] then E.bases[path] = M.base_of(path, read_of(E).lines(path)) end
    return E.bases[path]
end

-- the one best-ranked item of a result, or nil
local function decided(res)
    if res.jump then return res.jump end
    local best, pick = math.huge, nil
    for _, it in ipairs(res.pool or {}) do
        if (it.rank or 0) < best then
            best, pick = it.rank or 0, it
        elseif (it.rank or 0) == best then
            pick = nil
        end
    end
    return pick
end

local type_of

local function value_type(ctx, E, base, lnum, col, depth)
    if depth >= MAX_DEPTH then return nil end
    local vctx = M.context_at(base, lnum, col)
    local it = vctx and decided(M.resolve(vctx, E, { depth = depth + 1 }))
    return it and it.sym and type_of(ctx, E, it, depth + 1)
end

type_of = function(ctx, E, it, depth)
    local src = type_source(ctx, E, it)
    if not src or not src.expr then return src end
    return value_type(ctx, E, base_for(ctx, E, src.path), src.expr.lnum, src.expr.col, depth or 0)
end

-- type of the receiver's last segment (its own receiver: the rest of the chain)
local function receiver_type(ctx, r, E, depth)
    if r.kind == "call" then return value_type(ctx, E, ctx, r.lnum, r.col, depth) end
    if r.kind ~= "chain" or r.ctor then return nil end
    local col = r.col
    if #r.segs > 1 then col = col + #table.concat(r.segs, ".", 1, #r.segs - 1) + 1 end
    return value_type(ctx, E, ctx, r.lnum, col, depth)
end

-- does the chain start at `this`, a decl of this buffer or an imported value?
local function cheap_root(ctx, r)
    for _ = 1, MAX_DEPTH do
        if r.kind == "this" or r.kind == "super" then return true end
        local l, c, w
        if r.kind == "chain" then
            l, c, w = r.lnum, r.col, r.segs[1]
        elseif r.kind == "call" then
            local cctx = M.context_at(ctx, r.lnum, r.col)
            if not cctx then return false end
            if not cctx.recv then
                l, c, w = r.lnum, r.col, cctx.word
            else
                r = cctx.recv
            end
        else
            return false
        end
        if w then
            return not w:match("^%u") and (local_decl(ctx, w, l, c) ~= nil or ctx.hdr.explicit[w] ~= nil)
        end
    end
    return false
end

local function type_result(ctx, E, t)
    if t.self then return { jump = t.self, here = t.self.filename == ctx.path } end
    local base = t.path and base_for(ctx, E, t.path) or ctx
    local tctx = M.name_context(base, t.name)
    local qual = t.qual or base.hdr.explicit[t.name]
    if qual then
        return project(tctx, t.name, { qualifier = qual, pkg_dir = pkg_dir(qual), kind = "type" }, E)
    end
    for _, d in ipairs(scope.decls(base.sc, t.name)) do
        if d.kind == "type" then
            return { jump = here_item(base, d), here = base.path == ctx.path }
        end
    end
    return project(tctx, t.name, { kind = "type", implicit = {} }, E)
end

local function header_supers(base, it)
    local impl = require("kotlin-lite.impl")
    local text = impl.header_text(base.sc.lines, it.lnum)
    if it.filename:sub(-5) == ".java" then return java_supers(text) end
    local h = impl.parse_header(text)
    return vim.tbl_map(last_seg, h and h.supers or {})
end

--- Go to super: a type's supertypes, the member an override overrides.
function M.super_at(ctx, E)
    local res = M.resolve(ctx, E, { stay = true })
    if res.err then return res end
    local it = decided(res)
    local s = it and it.sym
    if not s then return { err = "'" .. ctx.word .. "' is ambiguous" } end
    local base = base_for(ctx, E, it.filename)
    if s.kind == "type" then
        local items = {}
        for _, n in ipairs(header_supers(base, it)) do
            local d = decided(type_result(ctx, E, { name = n, path = it.filename }))
            if d then items[#items + 1] = d end
        end
        if #items == 0 then return { err = "no supertype of '" .. s.name .. "' found" } end
        if #items == 1 then return { jump = items[1], here = items[1].filename == ctx.path } end
        return { pool = items, word = s.name }
    end
    if (s.kind == "fun" or s.kind == "prop") and s.owners[1] then
        local o = decided(type_result(ctx, E, { name = s.owners[1].name, path = it.filename }))
        local supers = o and header_supers(base_for(ctx, E, o.filename), o) or {}
        if #supers > 0 then
            local r = project(M.name_context(base, s.name), s.name, { levels = { supers }, strict = true }, E)
            if r.jump then r.here = r.jump.filename == ctx.path end
            if not r.err then return r end
        end
    end
    return { err = "no super declaration of '" .. s.name .. "' found" }
end

--- grt
function M.type_at(ctx, E)
    local res = M.resolve(ctx, E, { stay = true })
    if res.err then return res end
    local it = decided(res)
    if not it then return { err = "'" .. ctx.word .. "' is ambiguous" } end
    local t = it.sym and type_of(ctx, E, it, 0)
    if not t then return { err = "no type known for '" .. ctx.word .. "'" } end
    return type_result(ctx, E, t)
end

-------------------------------------------------------------------
-- lambdas with a receiver
-------------------------------------------------------------------

-- identifier before (l, col), past one (...) and <...> -> line, col, name
local function ident_before(sc, l, c)
    local m = sc.mask
    local function prev()
        c = c - 1
        while c < 0 do
            l = l - 1
            if l < 1 then return nil end
            c = #m[l] - 1
        end
        return m[l]:sub(c + 1, c + 1)
    end
    local ch = prev()
    while ch and ch:match("%s") do ch = prev() end
    for _, pair in ipairs({ { ")", "(" }, { ">", "<" } }) do
        if ch == pair[1] then
            local depth = 1
            while depth > 0 do
                ch = prev()
                if not ch then return nil end
                if ch == pair[1] then depth = depth + 1 elseif ch == pair[2] then depth = depth - 1 end
            end
            ch = prev()
            while ch and ch:match("%s") do ch = prev() end
        end
    end
    if not ch or not ch:match("[%w_]") then return nil end
    local e = c + 1
    local s0 = m[l]:sub(1, e):match("()[%a_][%w_]*$")
    if not s0 then return nil end
    return l, s0 - 1, m[l]:sub(s0, e)
end

-- T of the last `T.() -> ...` param of the fun at (lnum, col), not a type param
local function receiver_param(lines, lnum, col)
    local m = scope.mask(vim.list_slice(lines, lnum, lnum + 40))
    local text = table.concat(m, "\n")
    local from = col + 1
    local open = text:find("(", from, true)
    if not open then return nil end
    local params = text:match("^%b()", open)
    if not params then return nil end
    local generics = {}
    for g in (text:sub(1, open):match("%f[%w_]fun%s*(%b<>)") or ""):gmatch("[%a_][%w_]*") do
        generics[g] = true
    end
    local t
    for r in params:gsub("%b<>", ""):gmatch("([%w_.]+)%s*%.%s*%(%s*%)%s*%->") do t = r end
    t = last_seg(t)
    return t and not generics[t] and t or nil
end

-- receiver type of lambda `b`: apply / run / with -> x's type, else the
-- `T.() -> ...` param of the callee (costs resolving it)
local function lambda_receiver(ctx, b, E)
    local ol, oc = scope.unkey(b.open)
    local l, c, name = ident_before(ctx.sc, ol, oc)
    if name == "apply" or name == "run" then
        local cctx = M.context_at(ctx, l, c)
        local opts = cctx and cctx.recv and receiver_opts(cctx, cctx.recv) or {}
        return opts.levels and opts.levels[1][1]
    elseif name == "with" then
        local arg = ctx.sc.mask[l]:sub(c + #name + 1):match("^%s*%(%s*()")
        local actx = arg and M.context_at(ctx, l, c + #name + arg - 1)
        if actx and actx.word:match("^%u") and actx.call then return actx.word end
        local d = actx and local_decl(ctx, actx.word, actx.lnum, actx.s)
        return d and type_of_decl(ctx.sc, d, actx.word)
    elseif name then
        local cctx = M.context_at(ctx, l, c)
        local res = cctx and M.resolve(cctx, E)
        for _, d in ipairs(res and (res.jump and { res.jump } or res.pool) or {}) do
            local lines = lines_for(ctx, E, d.filename, d.lnum)
            local t = receiver_param(lines, d.lnum, (d.col or 1) - 1)
            if t then return t end
        end
    end
    return nil
end

-- start the callee search of lambda `b` early, in case it's needed
local function prefetch_callee(ctx, b, E)
    if not b then return end
    local ol, oc = scope.unkey(b.open)
    local l, c, name = ident_before(ctx.sc, ol, oc)
    if not name or name == "apply" or name == "run" or name == "with" then return end
    local cctx = M.context_at(ctx, l, c)
    if not cctx or cctx.recv then return end
    local args = project_args(cctx, name, {})
    start(E, args, { search.root() })
    local jar_dirs = jars.jar_dirs()
    if #jar_dirs > 0 then start(E, args, jar_dirs) end
end

local function member_in_buffer(ctx, levels)
    local decls
    for _, names in ipairs(levels) do
        local set = {}
        for _, n in ipairs(names) do set[n] = true end
        local blocks = scope.type_blocks(ctx.sc, set)
        if next(blocks) then
            decls = decls or scope.decls(ctx.sc, ctx.word)
            for _, d in ipairs(decls) do
                if d.member_of and blocks[d.member_of] and scope.key(d.lnum, d.col) ~= ctx.pos then
                    return d
                end
            end
        end
    end
    return nil
end

-- on a declaration: `override` -> super member, `actual` -> expect, else
-- (or opts.stay) itself; nil when not on a declaration
local function own_decl(ctx, E, opts)
    local own
    for _, d in ipairs(scope.decls(ctx.sc, ctx.word)) do
        if d.lnum == ctx.lnum and d.col == ctx.s then own = d break end
    end
    if not own then return nil end
    local stay = { jump = here_item(ctx, own), here = true }
    if is_local(ctx.sc, own) or opts.stay then return stay end

    local mods = ctx.sc.mask[ctx.lnum]:sub(1, ctx.s)
    if mods:find("%f[%w_]override%f[^%w_]") then
        local owner = own.member_of or (own.scope.kind == "type" and own.scope)
        local supers = owner and vim.tbl_map(last_seg, owner.supers or {}) or {}
        if #supers > 0 then
            local res = project(ctx, ctx.word, { levels = { supers }, strict = true }, E)
            if not res.err then return res end
        end
    elseif mods:find("%f[%w_]actual%f[^%w_]") then
        local res = project(ctx, ctx.word, {}, E)
        local expects = vim.tbl_filter(function(it)
            return it.filename ~= ctx.path and it.pkg == ctx.hdr.package
                and not it.text:find("%f[%w_]actual%f[^%w_]")
        end, res.pool or (res.jump and { res.jump }) or {})
        if #expects == 1 then return { jump = expects[1] } end
        if #expects > 1 then return { pool = expects, word = ctx.word } end
    end
    return stay
end

-------------------------------------------------------------------
-- entry point
-------------------------------------------------------------------

-- kill unawaited searches (prefetches)
local function finish_engine(E)
    for _, h in pairs(E.memo or {}) do
        if not h.items then E.cancel(h) end
    end
end

--- Resolve `ctx` with rg engine `E` -> { jump, here? } | { pool, word } |
--- { err, level? }; items carry `sym`, pool items `rank`.
--- opts.stay: on a declaration, that one (not its super / expect)
function M.resolve(ctx, E, opts)
    opts = opts or {}
    local word = ctx.word
    if not ctx.lnum then return project(ctx, word, {}, E) end

    local imp = imports.import_target(ctx.line, word)
    if imp and imp.wildcard then
        return { err = "wildcard import of " .. imp.wildcard .. ", nothing to jump to", level = vim.log.levels.INFO }
    end
    imp = imp or ctx.hdr.aliases[word]
    if imp then
        return project(ctx, imp.name, {
            qualifier = imp.qualifier, pkg_dir = pkg_dir(imp.qualifier), import_line = true,
        }, E)
    end

    if ctx.code then
        local na = named_arg(ctx.sc, ctx.lnum, ctx.s, ctx.e)
        local res = na and named_param(ctx, na, E)
        if res then return res end
    end

    if ctx.recv then
        local ro = receiver_opts(ctx, ctx.recv)
        local d = ro.levels and member_in_buffer(ctx, ro.levels)
        if d then return { jump = here_item(ctx, d), here = true } end
        local res = project(ctx, word, ro, E)
        if ro.levels or res.sole or (opts.depth or 0) >= MAX_DEPTH
            or not cheap_root(ctx, ctx.recv) then
            return res
        end
        -- several candidates: look the receiver's type up
        local t = receiver_type(ctx, ctx.recv, E, opts.depth or 0)
        if t and t.self then t = { name = t.self.sym.name } end
        if not t or t.name:match("^%u%d?$") then return res end -- (a type parameter)
        local levels = { { t.name } }
        d = member_in_buffer(ctx, levels)
        if d then return { jump = here_item(ctx, d), here = true } end
        local typed = project(ctx, word, { levels = levels }, E)
        if typed.err then return res end
        for _, it in ipairs(res.jump and typed.pool or {}) do
            if it.filename == res.jump.filename and it.lnum == res.jump.lnum then return res end
        end
        return typed
    end

    local own = own_decl(ctx, E, opts)
    if own then return own end
    local d = search.decl_in_buffer(word, ctx.sc, ctx.lnum, ctx.s)
    if d then return { jump = here_item(ctx, d), here = true } end
    local implicit, open, lambdas = implicit_receivers(ctx)
    local explicit = ctx.hdr.explicit[word]
    if explicit then
        -- imported by name: that package or nothing (JDK, unextracted jar)
        return project(ctx, word, { qualifier = explicit, pkg_dir = pkg_dir(explicit) }, E)
    end
    prefetch_callee(ctx, lambdas[1], E)
    local res = project(ctx, word, { implicit = implicit, open = open }, E)
    if res.jump or res.err or #lambdas == 0 then return res end
    -- undecided member / extension: try lambda receivers, innermost first
    local reachable = false
    for _, it in ipairs(res.pool or {}) do
        if (it.member and not it.imported) or it.ext then reachable = true break end
    end
    if res.pool and not reachable then return res end
    for _, b in ipairs(lambdas) do
        local t = lambda_receiver(ctx, b, E)
        if t then
            local res2 = project(ctx, word, { levels = { { t } }, strict = true }, E)
            if not res2.err then return res2 end
        end
    end
    return res
end

--- fn(ctx, E) in a coroutine (ctx: default at the cursor; E: async engine)
function M.run(fn, what, ctx)
    if not ctx then
        local cur = vim.api.nvim_win_get_cursor(0)
        ctx = M.context_at(M.base(vim.api.nvim_get_current_buf()), cur[1], cur[2])
    end
    if not ctx then return end
    local E = search.engine(true)
    local co = coroutine.create(function()
        fn(ctx, E)
        finish_engine(E)
    end)
    local ok, err = coroutine.resume(co)
    if not ok then
        vim.notify("kotlin-lite: " .. (what or "gd") .. " failed: " .. tostring(err), vim.log.levels.ERROR)
    end
end

function M.at_cursor(cb, what)
    M.run(function(ctx, E)
        local res = M.resolve(ctx, E)
        finish_engine(E)
        cb(res)
    end, what)
end

function M.run_sync(ctx, opts)
    local E = search.engine(false)
    local res = M.resolve(ctx, E, opts)
    finish_engine(E)
    return res
end

--- for 'tagfunc': at the cursor, or a bare name
function M.sync(word, at_cursor)
    local base = M.base(vim.api.nvim_get_current_buf())
    local ctx
    if at_cursor then
        local cur = vim.api.nvim_win_get_cursor(0)
        ctx = M.context_at(base, cur[1], cur[2])
        if ctx and ctx.word ~= word then ctx = nil end
    end
    return M.run_sync(ctx or M.name_context(base, word))
end

-- building blocks for usages.lua
M.receiver, M.named_arg, M.declared_type = receiver, named_arg, type_of_decl
M.is_local, M.decided = is_local, decided

return M
