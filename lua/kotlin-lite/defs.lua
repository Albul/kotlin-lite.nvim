-- Definition picker rows: drop stale jar versions, split each declaration into
-- columns (expect/actual, signature, source set, origin + file:line) and sort
-- header-matched (imports.rank_items) first, then expect before actual.

local jars = require("kotlin-lite.jars")

local M = {}

local function cfg()
    return require("kotlin-lite.config").options
end

local SIG_MAX = 60

-- modifiers that only add noise in a one-line summary
local NOISE = {
    public = true, private = true, protected = true, internal = true,
    expect = true, actual = true, override = true, open = true,
    abstract = true, final = true, external = true,
}

-------------------------------------------------------------------
-- jar origin
-------------------------------------------------------------------

-- { dir, rel, artifact, version } for a file inside an extracted jar, else nil.
-- `labels` memoizes .jarname reads per jar dir.
local function jar_info(file, labels)
    if not jars.is_jar(file) then return nil end
    local dir_name, rel = file:match("^" .. vim.pesc(cfg().cache_dir) .. "/([^/]+)/(.*)$")
    if not dir_name then return nil end
    local dir = cfg().cache_dir .. "/" .. dir_name
    local info = labels and labels[dir]
    if not info then
        local artifact, version = jars._parse_nv(jars.jar_label(dir))
        info = { artifact = artifact, version = version }
        if labels then labels[dir] = info end
    end
    return { dir = dir, rel = rel, artifact = info.artifact, version = info.version }
end
M._jar_info = jar_info

-- Keep jar matches only from the newest extracted version of each artifact.
-- A source file shipped in several artifacts (KMP common sources) counts once,
-- from the shortest artifact name (ui-graphics over ui-graphics-desktop).
function M.latest_only(items)
    local labels, newest = {}, {}
    for _, it in ipairs(items) do
        local j = jar_info(it.filename, labels)
        if j then
            local cur = newest[j.artifact]
            if not cur or jars._ver_lt(cur, j.version) then newest[j.artifact] = j.version end
        end
    end
    local kept = vim.tbl_filter(function(it)
        local j = jar_info(it.filename, labels)
        return not j or newest[j.artifact] == j.version
    end, items)

    local base = {} -- "rel:lnum" -> item
    for _, it in ipairs(kept) do
        local j = jar_info(it.filename, labels)
        if j then
            local key = j.rel .. ":" .. it.lnum
            local cur = base[key]
            if not cur or #j.artifact < #jar_info(cur.filename, labels).artifact then base[key] = it end
        end
    end
    return vim.tbl_filter(function(it)
        local j = jar_info(it.filename, labels)
        return not j or base[j.rel .. ":" .. it.lnum] == it
    end, kept)
end

-------------------------------------------------------------------
-- row parts
-------------------------------------------------------------------

-- "commonMain" -> "common", "jvmTest" -> "jvmTest", "main" -> nil
local function source_set(path)
    for seg in path:gmatch("[^/]+") do
        local s = seg:match("^(%l%w*)Main$")
        if s then return s end
        if seg:match("^%l%w*Test$") then return seg end
    end
    return nil
end
M._source_set = source_set

-- project module = path before the first "src/" ("" at the root); outside a
-- src/ layout, the file's directory
local function module_of(rel)
    local mod = rel:match("^(.-)/?src/")
    if mod then return mod end
    local dir = vim.fs.dirname(rel)
    return dir == "." and "" or dir
end

-- strip visibility / expect / actual / ... and the trailing "{"
local function signature(text)
    local rest, mp = text, nil
    while true do
        local w, tail = rest:match("^(%l+)%s+(.*)$")
        if not w or not NOISE[w] then break end
        if w == "expect" or w == "actual" then mp = w end
        rest = tail
    end
    rest = rest:gsub("%s*{%s*$", ""):gsub("%s*=%s*$", "")
    return rest, mp
end
M._signature = signature

--- Split a rg item into display columns.
--- @return { mp:string?, sig:string, sset:string?, origin:string, file:string, lnum:integer, jar:boolean }
function M.describe(it, labels)
    local sig, mp = signature(it.text or "")
    local j = jar_info(it.filename, labels)
    local origin, path
    if j then
        origin = j.artifact .. (j.version ~= "" and (" " .. j.version) or "")
        path = j.rel
    else
        path = vim.fn.fnamemodify(it.filename, ":.")
        origin = module_of(path)
    end
    return {
        mp = mp,
        sig = sig,
        sset = source_set(path),
        origin = origin,
        file = vim.fs.basename(it.filename),
        lnum = it.lnum,
        jar = j ~= nil,
    }
end

local MP_RANK = { expect = 0, actual = 2 }

-- header rank (imports.rank_items) first, then project before jars, expect /
-- plain before actual, then source set + location
local function before(a, b)
    local ka, kb = a.it.rank or 0, b.it.rank or 0
    if ka ~= kb then return ka < kb end
    if a.d.jar ~= b.d.jar then return not a.d.jar end
    local ra, rb = MP_RANK[a.d.mp] or 1, MP_RANK[b.d.mp] or 1
    if ra ~= rb then return ra < rb end
    for _, k in ipairs({ "sset", "origin", "file" }) do
        local x, y = a.d[k] or "", b.d[k] or ""
        if x ~= y then return x < y end
    end
    return a.d.lnum < b.d.lnum
end

local function pad(s, w)
    return s .. string.rep(" ", w - vim.fn.strdisplaywidth(s))
end

local function clip(s, w)
    if vim.fn.strchars(s) <= w then return s end
    return vim.fn.strcharpart(s, 0, w - 1) .. "…"
end

--- Picker rows for definition matches: sorted, aligned, with highlight chunks.
--- Each row: { text, display, chunks, data = item, file, pos }
function M.rows(items)
    local labels, rows = {}, {}
    for _, it in ipairs(items) do
        rows[#rows + 1] = { it = it, d = M.describe(it, labels) }
    end
    table.sort(rows, before)

    -- mark the rows the file header points at, but only when some rows don't
    -- qualify -- an all-marked list says nothing
    local top = rows[1] and rows[1].it.rank
    local mixed = top and top < rows[#rows].it.rank

    local w = { mp = 0, sig = 0, sset = 0 }
    for _, r in ipairs(rows) do
        r.d.sig = clip(r.d.sig, SIG_MAX)
        w.mp = math.max(w.mp, #(r.d.mp or ""))
        w.sig = math.max(w.sig, vim.fn.strdisplaywidth(r.d.sig))
        w.sset = math.max(w.sset, #(r.d.sset or ""))
    end

    local out = {}
    for _, r in ipairs(rows) do
        local d = r.d
        local loc = d.file .. ":" .. d.lnum
        local where = d.origin ~= "" and (d.origin .. " · " .. loc) or loc
        local chunks = {}
        local function add(s, hl) chunks[#chunks + 1] = { s, hl } end
        if mixed then add(r.it.rank == top and "● " or "  ", "DiagnosticOk") end
        if w.mp > 0 then add(pad(d.mp or "", w.mp) .. "  ", d.mp and "Keyword" or nil) end
        add(pad(d.sig, w.sig) .. "  ")
        if w.sset > 0 then add(pad(d.sset or "", w.sset) .. "  ", "Type") end
        add(where, "Comment")

        local line = {}
        for _, c in ipairs(chunks) do line[#line + 1] = c[1] end
        local display = table.concat(line)
        out[#out + 1] = {
            text = display,
            display = display,
            chunks = chunks,
            data = r.it,
            file = r.it.filename,
            pos = { r.it.lnum, math.max((r.it.col or 1) - 1, 0) },
        }
    end
    return out
end

return M
