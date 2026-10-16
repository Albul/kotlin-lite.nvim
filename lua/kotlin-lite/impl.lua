-- Go to implementation (gri):
--   type (interface / abstract / open / sealed class)  -> subtypes, transitively
--   member (fun / val / var)                           -> overrides in those subtypes
--   expect class / member                              -> its actuals
-- Supertype references are checked against each file's package + imports, so a
-- same-named type from another package is not mistaken for the target.

local search = require("kotlin-lite.search")
local imports = require("kotlin-lite.imports")
local defs = require("kotlin-lite.defs")

local M = {}

local MAX_TYPES = 400 -- transitive subtype walk budget (stdlib Collection: ~200)

local TYPE_KW = { class = true, interface = true, object = true }
local MODIFIERS = {
    public = true, private = true, protected = true, internal = true,
    abstract = true, open = true, final = true, sealed = true, data = true,
    enum = true, annotation = true, inner = true, value = true, inline = true,
    expect = true, actual = true, external = true, companion = true, fun = true,
}

-------------------------------------------------------------------
-- class header parsing
-------------------------------------------------------------------

-- index just past the balanced (...) or <...> group opening at s[i]
local function skip_group(s, i)
    local open = s:sub(i, i)
    local close = open == "(" and ")" or ">"
    local depth = 0
    for j = i, #s do
        local c = s:sub(j, j)
        if c == open then
            depth = depth + 1
        elseif c == close then
            depth = depth - 1
            if depth == 0 then return j + 1 end
        end
    end
    return #s + 1
end

-- "A, B<C, D>(x), E by e {" -> { "A", "B", "E" }; stops at a depth-0 "{"
local function split_supers(s)
    local out, depth, start = {}, 0, 1
    local function push(stop)
        local name = s:sub(start, stop):match("^%s*([%w_.]+)")
        if name and name ~= "" then out[#out + 1] = name end
    end
    for i = 1, #s do
        local c = s:sub(i, i)
        if c == "(" or c == "<" then
            depth = depth + 1
        elseif c == ")" or c == ">" then
            depth = depth - 1
        elseif depth == 0 and c == "," then
            push(i - 1)
            start = i + 1
        elseif depth == 0 and (c == "{" or s:sub(i):match("^%f[%w_]where%f[^%w_]")) then
            push(i - 1)
            return out
        end
    end
    push(#s)
    return out
end

--- Parse a class / interface / object header (possibly joined from several
--- lines). Anonymous `object : T` is recognised anywhere in the text.
--- @return { kind:string, name:string?, mods:table<string,true>, supers:string[] }?
function M.parse_header(text)
    text = text:gsub("%->", "  ") -- function types: keep '>' for generics only
    local mods, i, kind = {}, 1, nil
    while i <= #text do
        i = text:find("%S", i) or #text + 1
        local c = text:sub(i, i)
        if c == "@" then
            local _, e = text:find("^@[%w_.:]+", i)
            i = (e or i) + 1
            if text:sub(i, i) == "(" then i = skip_group(text, i) end
        else
            local word = text:match("^[%a_][%w_]*", i)
            if not word then break end
            i = i + #word
            if TYPE_KW[word] then
                kind = word
                break
            elseif MODIFIERS[word] then
                mods[word] = true
            else
                break
            end
        end
    end

    local name
    if kind then
        if mods.fun and kind ~= "interface" then return nil end
        mods.fun = nil
        name = text:match("^%s+([%w_]+)", i)
        if name then i = text:find("[%w_]", i) + #name end
    else
        -- anonymous object in an expression: `= object : T {`, `(object : T {`
        local s = text:find("%f[%w_]object%s*:")
        if not s then return nil end
        kind, mods, i = "object", {}, s + #"object"
    end
    if kind == "object" and not name and mods.companion then name = "Companion" end

    -- generics, then annotations / visibility / `constructor`, then the ctor params
    i = text:find("%S", i) or #text + 1
    if text:sub(i, i) == "<" then i = skip_group(text, i) end
    while true do
        i = text:find("%S", i) or #text + 1
        local c = text:sub(i, i)
        if c == "@" then
            local _, e = text:find("^@[%w_.:]+", i)
            i = (e or i) + 1
            if text:sub(i, i) == "(" then i = skip_group(text, i) end
        else
            local word = text:match("^[%a_][%w_]*", i)
            if word and (word == "constructor" or MODIFIERS[word]) then
                i = i + #word
            else
                break
            end
        end
    end
    if text:sub(i, i) == "(" then i = skip_group(text, i) end
    i = text:find("%S", i) or #text + 1

    local supers = {}
    if text:sub(i, i) == ":" then supers = split_supers(text:sub(i + 1)) end
    return { kind = kind, name = name, mods = mods, supers = supers }
end

local function paren_depth(s)
    local _, o = s:gsub("%(", "")
    local _, c = s:gsub("%)", "")
    return o - c
end

-- header text starting at lines[l], joined while the header obviously goes on
-- (open parens, trailing ':' / ',', next line starting with ':' ',' ')' 'where');
-- also returns the header's last line
local function header_text(lines, l)
    local acc, j = lines[l], l
    while j < math.min(#lines, l + 30) do
        if acc:find("{") and paren_depth(acc) <= 0 then break end
        local cur, nxt = vim.trim(lines[j]), vim.trim(lines[j + 1] or "")
        if paren_depth(acc) > 0 or cur:match("[:,]$") or nxt:match("^[:,)]")
            or nxt:match("^where%f[^%w_]") then
            j = j + 1
            acc = acc .. " " .. lines[j]
        else
            break
        end
    end
    return acc, j
end
M.header_text = header_text

-------------------------------------------------------------------
-- per-run file cache: lines, package, header ctx, class headers
-------------------------------------------------------------------

local function indent(line)
    return #(line:match("^%s*"))
end

local function new_cache(read)
    local files = {}
    local cache = {}

    function cache.file(path)
        local f = files[path]
        if f then return f end
        f = { path = path, lines = read.lines(path) }
        files[path] = f
        return f
    end

    function cache.ctx(path)
        return read.header(path)
    end

    function cache.package(path)
        return read.package(path)
    end

    -- class header starting at line `l` (cached), or nil
    function cache.header_at(path, l)
        local f = cache.file(path)
        f.headers = f.headers or {}
        local h = f.headers[l]
        if h ~= nil then return h or nil end
        h = false
        local line = f.lines[l] or ""
        local stripped = vim.trim(line)
        if stripped:sub(1, 2) ~= "//" and stripped:sub(1, 1) ~= "*"
            and (line:find("%f[%w_]class%f[^%w_]") or line:find("%f[%w_]interface%f[^%w_]")
                or line:find("%f[%w_]object%f[^%w_]")) then
            local text, last = header_text(f.lines, l)
            local parsed = M.parse_header(text)
            if parsed then
                parsed.lnum, parsed.last = l, last
                parsed.col = line:find("%S") or 1
                h = parsed
            end
        end
        f.headers[l] = h
        return h or nil
    end

    -- the class header spanning line `lnum` (a multi-line header may start above)
    function cache.header_covering(path, lnum)
        for l = lnum, math.max(1, lnum - 30), -1 do
            local h = cache.header_at(path, l)
            if h then return h.last >= lnum and h or nil end
        end
        return nil
    end

    -- the class header whose body / ctor holds line `lnum`, or nil at top level
    function cache.enclosing(path, lnum)
        local f = cache.file(path)
        local want = indent(f.lines[lnum] or "")
        for l = lnum - 1, 1, -1 do
            local line = f.lines[l]
            local s = vim.trim(line)
            if s ~= "" and indent(line) < want and not s:match("^[})]")
                and s:sub(1, 1) ~= "*" and s:sub(1, 2) ~= "//" and s:sub(1, 1) ~= "@" then
                return cache.header_at(path, l)
            end
        end
        return nil
    end

    return cache
end

-------------------------------------------------------------------
-- searches
-------------------------------------------------------------------

-- does supertype reference `ref` (as written in `path`) mean type `t`?
local function refers(cache, path, ref, t)
    if ref:match("([%w_]+)$") ~= t.name then return false end
    if ref:find(".", 1, true) then
        -- qualified: full name, or Outer.T (a nested type, can't verify cheaply)
        return ref == (t.pkg and (t.pkg .. "." .. t.name)) or ref:match("^%u") ~= nil
    end
    return imports.rank(cache.ctx(path), t.name, t.pkg) < imports.NONE
end

local function item_of(cache, path, lnum, col)
    return {
        filename = path,
        lnum = lnum,
        col = col or 1,
        text = vim.trim(cache.file(path).lines[lnum] or ""),
    }
end

-- can this rg hit be part of a class header? (skips the bulk of type mentions:
-- params, properties, return types -- before any file is read)
--   `class X : T`, `...) : T {` (end of a multi-line ctor), `: T,`, and an
--   own-line supertype list `A, T<E>, B {`
local function header_line(it)
    local t = it.text
    if t:find("%f[%w_]class%f[^%w_]") or t:find("%f[%w_]interface%f[^%w_]")
        or t:find("%f[%w_]object%f[^%w_]") or t:match("^[):]") or t:find("%)%s*:") then
        return true
    end
    -- `name: Type` is a parameter / property, not a supertype entry
    return (t:match("^[%w_.]+%s*[<,({]") or t:match("^[%w_.]+%s*$")) ~= nil
end

-- does header `h` (in `path`) list one of the `by_name` types as a supertype?
local function extends(cache, path, h, by_name)
    for _, ref in ipairs(h.supers) do
        for _, t in ipairs(by_name[ref:match("([%w_]+)$")] or {}) do
            if refers(cache, path, ref, t) then return true end
        end
    end
    return false
end

-- all subtypes of { name, pkg }, transitively: one rg per hierarchy level, all
-- of that level's type names in a single alternation.
-- -> list of { item, header, key = "file:lnum" }
local function subtypes(cache, root, dirs, E)
    local out, seen_types, seen_hdr = {}, {}, {}
    seen_types[(root.pkg or "") .. "." .. root.name] = true
    local level, budget = { root }, MAX_TYPES
    while #level > 0 and budget > 0 do
        budget = budget - #level
        local by_name, names = {}, {}
        for _, t in ipairs(level) do
            if not by_name[t.name] then
                by_name[t.name] = {}
                names[#names + 1] = t.name -- [%w_] only: safe in a regex as is
            end
            table.insert(by_name[t.name], t)
        end
        local alt = "(" .. table.concat(names, "|") .. ")"
        local found = E.run({
            "-e", [=[[:,]\s*([\w.]+\.)?]=] .. alt .. [=[\b]=],
            "-e", [=[^\s*([\w.]+\.)?]=] .. alt .. [=[\b]=],
        }, dirs)

        local next_level = {}
        for _, it in ipairs(found) do
            local path = it.filename
            local h = header_line(it) and cache.header_covering(path, it.lnum)
            local key = h and (path .. ":" .. h.lnum)
            if h and not seen_hdr[key] and extends(cache, path, h, by_name) then
                seen_hdr[key] = true
                out[#out + 1] = { item = item_of(cache, path, h.lnum, h.col), header = h, key = key }
                -- objects are final; anything else may have subtypes of its own
                if h.name and h.kind ~= "object" then
                    local pkg = cache.package(path)
                    local id = (pkg or "") .. "." .. h.name
                    if not seen_types[id] then
                        seen_types[id] = true
                        next_level[#next_level + 1] = { name = h.name, pkg = pkg }
                    end
                end
            end
        end
        level = next_level
    end
    return out
end

-- `actual` counterparts of an expect decl `word` in package `pkg`; for members,
-- only those inside an actual class named `owner`
local function actuals(cache, word, pkg, owner, dirs, E)
    local out = {}
    for _, it in ipairs(E.run(search.decl_args(word), dirs)) do
        if it.text:find("%f[%w_]actual%f[^%w_]") and cache.package(it.filename) == pkg then
            local enc = cache.enclosing(it.filename, it.lnum)
            local enc_name = enc and enc.name
            if enc_name == owner then out[#out + 1] = it end
        end
    end
    return out
end

-- `override fun|val|var word` declared inside one of `subs`
local function overrides(cache, word, subs, dirs, E)
    local keys = {}
    for _, s in ipairs(subs) do keys[s.key] = true end
    local w = word
    local found = E.run({ "-e",
        [=[\boverride\b.*\b(fun|val|var)\s+(<[^>]*>\s+)?([\w.<>?,\s]+\.)?]=] .. w .. [=[\b]=] }, dirs)
    local out = {}
    for _, it in ipairs(found) do
        local enc = cache.enclosing(it.filename, it.lnum)
        if enc and keys[it.filename .. ":" .. enc.lnum] then out[#out + 1] = it end
    end
    return out
end

-------------------------------------------------------------------
-- entry point
-------------------------------------------------------------------

local function choose(pool, word)
    local co = coroutine.running()
    require("kotlin-lite.picker").select(defs.rows(pool), {
        prompt = "Implementations of which " .. word .. "?",
    }, function(it) coroutine.resume(co, it) end)
    return coroutine.yield()
end

-- resolve result -> declarations to search from, or nil + message
local function declarations(res)
    if res.err then return nil, res.err end
    if res.jump then return { res.jump } end
    -- KMP: the expect is the declaration, the actuals are the answer
    local expects = vim.tbl_filter(function(it) return it.sym.mp == "expect" end, res.pool)
    if #expects > 0 then return expects end
    local best = math.huge
    for _, it in ipairs(res.pool) do best = math.min(best, it.rank or 0) end
    local top = vim.tbl_filter(function(it) return (it.rank or 0) == best end, res.pool)
    if #top == 1 then return top end
    -- an override is an implementation itself: ask only about the rest
    local roots = vim.tbl_filter(function(it)
        return not it.text:find("%f[%w_]override%f[^%w_]")
    end, top)
    if #roots == 1 then return roots end
    local picked = choose(#roots > 0 and roots or res.pool, res.word)
    return picked and { picked } or nil
end

--- Implementations of `decl` (by its `sym`); runs in a coroutine.
function M.find(decl, cache, dirs, E)
    local s = decl.sym
    local results = {}
    if s.kind == "type" then
        for _, t in ipairs(subtypes(cache, { name = s.name, pkg = s.pkg }, dirs, E)) do
            results[#results + 1] = t.item
        end
        if s.mp == "expect" then
            vim.list_extend(results, actuals(cache, s.name, s.pkg, s.owners[1] and s.owners[1].name, dirs, E))
        end
        return results
    end
    if s.kind ~= "fun" and s.kind ~= "prop" then return results end

    -- member: overrides inside subtypes of the owner (+ actuals of an expect member)
    local owner = s.owners[1]
    if s.mp == "expect" then
        vim.list_extend(results, actuals(cache, s.name, s.pkg, owner and owner.name, dirs, E))
    end
    if owner and owner.name then
        local subs = subtypes(cache, { name = owner.name, pkg = s.pkg }, dirs, E)
        vim.list_extend(results, overrides(cache, s.name, subs, dirs, E))
    end
    return results
end

--- Names of `root` ({ name, pkg }) and its project subtypes.
function M.type_family(root, E)
    local cache = new_cache(require("kotlin-lite.resolve").reader_of(E))
    local set = { [root.name] = true }
    for _, t in ipairs(subtypes(cache, root, { search.root() }, E)) do
        if t.header.name then set[t.header.name] = true end
    end
    return set
end

local function dedupe(items)
    local seen, out = {}, {}
    for _, it in ipairs(items) do
        local key = it.filename .. ":" .. it.lnum
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = it
        end
    end
    return out
end

function M.goto_implementation()
    local word = vim.fn.expand("<cword>")
    if word == "" then return end
    local actions = require("kotlin-lite.actions")
    local resolve = require("kotlin-lite.resolve")
    local origin = actions._tag_origin(word)
    local function go(it)
        actions._push_tag(origin)
        actions._jump(it)
    end

    resolve.run(function(ctx, E)
        local decls, err = declarations(resolve.resolve(ctx, E, { stay = true }))
        if not decls then
            if err then vim.notify("kotlin-lite: " .. err, vim.log.levels.WARN) end
            return
        end
        local name = decls[1].sym.name
        local cache, dirs, results = new_cache(resolve.reader_of(E)), search.search_dirs(), {}
        for _, d in ipairs(decls) do
            vim.list_extend(results, M.find(d, cache, dirs, E))
        end
        results = defs.latest_only(dedupe(results))
        if #results == 0 then
            vim.notify("kotlin-lite: no implementations of '" .. name .. "'", vim.log.levels.INFO)
        elseif #results == 1 then
            go(results[1])
        else
            require("kotlin-lite.picker").select(defs.rows(results), {
                prompt = "Implementations: " .. name,
            }, go)
        end
    end, "gri")
end

return M
