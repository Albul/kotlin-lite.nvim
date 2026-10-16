-- gu / rename: occurrences that mean the resolved declaration, by scope,
-- file header and receiver (no lookup per occurrence).

local search = require("kotlin-lite.search")
local scope = require("kotlin-lite.scope")
local imports = require("kotlin-lite.imports")
local jars = require("kotlin-lite.jars")
local resolve = require("kotlin-lite.resolve")
local resources = require("kotlin-lite.resources")

local M = {}

-- files filtered before keeping the rest as is
local SCAN_BUDGET = 400

local function file_lines(path)
    local b = vim.fn.bufnr(path)
    if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines or {}
end

local function occurrences(sc, word, l)
    local out, i, pat = {}, 1, "%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]"
    while true do
        local s, e = (sc.mask[l] or ""):find(pat, i)
        if not s then return out end
        out[#out + 1] = s - 1
        i = e + 1
    end
end

local function qf_item(path, sc, l, c, word)
    return {
        filename = path, lnum = l, col = c + 1, end_col = c + 1 + #word,
        text = vim.trim(sc.lines[l] or ""),
    }
end

-- where a declaration with visibility `vis` can be used
local function reach(path, vis)
    if vis == "private" then return path end
    if vis == "internal" then return path:match("^(.-)/src/") or search.root() end
    return search.root()
end

local function param_owner(d)
    local head = d.scope and d.scope.head or ""
    return head:match("%f[%w_]fun%s+[^(]-([%w_]+)%s*%(") or head:match("%f[%w_]class%s+([%w_]+)")
end

local function placed(sc, word, it)
    for _, d in ipairs(scope.decls(sc, word)) do
        if d.lnum == it.lnum and d.col == it.col - 1 then return d end
    end
end

local function enclosing_types(sc, p)
    local out = {}
    for _, b in ipairs(scope.enclosing(sc, p)) do
        if b.kind == "type" and b.name then out[#out + 1] = b.name end
        if b.kind == "fun" and b.ext then out[#out + 1] = b.ext end
    end
    return out
end

local function any(names, pred)
    for _, n in ipairs(names) do
        if pred(n) then return true end
    end
    return false
end

-- a param / local: its scope, plus named arguments at calls of its fun
local function local_usages(ctx, E, decl, word, out)
    local sc = ctx.sc
    local d = placed(sc, word, decl)
    if not d then return end
    local decls = scope.decls(sc, word)
    for l = scope.unkey(d.from), math.min(#sc.lines, (scope.unkey(d.to))) do
        for _, c in ipairs(occurrences(sc, word, l)) do
            local p = scope.key(l, c)
            local v = scope.visible(decls, p, nil)
            if v == d then out[#out + 1] = qf_item(ctx.path, sc, l, c, word) end
        end
    end
    local fn = d.kind == "param" and param_owner(d)
    if not fn then return end
    local here = {}
    for _, it in ipairs(out) do here[it.lnum .. ":" .. it.col] = true end
    local hits = E.run({ "-w", "-e", word }, { reach(ctx.path, decl.sym.vis) })
    local files = {}
    for _, it in ipairs(hits) do files[it.filename] = true end
    for path in pairs(files) do
        local fsc = path == ctx.path and sc or scope.scan(file_lines(path))
        for l = 1, #fsc.lines do
            for _, c in ipairs(occurrences(fsc, word, l)) do
                local na = resolve.named_arg(fsc, l, c, c + #word)
                local callee = na and fsc.mask[na.lnum]:match("^[%w_]+", na.col + 1)
                if callee == fn and not (path == ctx.path and here[l .. ":" .. (c + 1)]) then
                    out[#out + 1] = qf_item(path, fsc, l, c, word)
                end
            end
        end
    end
end

-- `it`: the occurrences its lambda declares
local function it_usages(ctx, lambda)
    local out = {}
    for l = scope.unkey(lambda.open), math.min(#ctx.sc.lines, (scope.unkey(lambda.close))) do
        for _, c in ipairs(occurrences(ctx.sc, "it", l)) do
            if not resolve.receiver(ctx.sc, l, c) and resolve.it_lambda(ctx.sc, scope.key(l, c)) == lambda then
                out[#out + 1] = qf_item(ctx.path, ctx.sc, l, c, "it")
            end
        end
    end
    return out
end

-- does the occurrence at (l, c) of `sc` (file `path`) mean `sym`?
local function means(S, path, sc, l, c)
    local sym, word = S.sym, S.sym.name
    local p = scope.key(l, c)
    if path == S.decl.filename and l == S.decl.lnum and c == S.decl.col - 1 then return true end
    local r = resolve.receiver(sc, l, c)
    local member = #sym.owners > 0

    local v = scope.visible(scope.decls(sc, word), p, nil)
    local own = v and path == S.decl.filename and v.lnum == S.decl.lnum and v.col == S.decl.col - 1
    if v and not own then
        if resolve.is_local(sc, v) then return false end
        if v.member_of then
            if not (member and v.member_of.name and S.family()[v.member_of.name]) and not r then return false end
        elseif not r then
            return false
        end
    end

    local na = not r and resolve.named_arg(sc, l, c, c + #word)
    if na then
        -- a parameter: of the ctor, for a ctor property
        local callee = sc.mask[na.lnum]:match("^[%w_]+", na.col + 1)
        return member and callee == sym.owners[1].name
    end

    if not member then
        if not r then return true end
        if sym.ext then return true end
        return r.kind == "chain" and table.concat(r.segs, ".") == sym.pkg
    end

    if not r then
        if own or v then return true end
        -- unqualified elsewhere: only through an implicit receiver
        local family = S.family()
        for _, b in ipairs(scope.enclosing(sc, p)) do
            if b.kind == "lambda" then return true end
        end
        return any(enclosing_types(sc, p), function(n) return family[n] end)
    end
    if r.kind == "this" or r.kind == "super" then
        local family = S.family()
        return any(enclosing_types(sc, p), function(n) return family[n] end)
    end
    if r.kind ~= "chain" then return true end
    local t
    if r.ctor or r.segs[#r.segs]:match("^%u") then
        t = r.segs[#r.segs]
    elseif #r.segs == 1 then
        local d = scope.visible(scope.decls(sc, r.segs[1]), scope.key(r.lnum, r.col), nil)
        t = d and resolve.declared_type(sc, d, r.segs[1])
    end
    if not t then return true end
    for _, o in ipairs(sym.owners) do
        if o.name == t then return true end
    end
    return S.family()[t] == true
end

--- -> { items, sym, decl, here_only } | { items, resource } | { unresolved = true, err? }
function M.find(ctx, E)
    local res = resolve.resolve(ctx, E, { stay = true })
    if res.err then return { unresolved = true, err = res.err } end
    if res.ref then return { items = resources.usages(res.ref, E), resource = res.label } end
    local decl = resolve.decided(res)
    if not decl or not decl.sym then return { unresolved = true } end
    local sym, word = decl.sym, decl.sym.name
    if decl.lambda then
        return { items = it_usages(ctx, decl.lambda), sym = sym, decl = decl, here_only = true }
    end
    local out = {}

    if sym.range and decl.filename == ctx.path then
        local_usages(ctx, E, decl, word, out)
        local here_only = true
        for _, it in ipairs(out) do
            if it.filename ~= ctx.path then here_only = false end
        end
        return { items = out, sym = sym, decl = decl, here_only = here_only }
    end

    local S = { sym = sym, decl = decl }
    local family
    function S.family()
        if not family then
            family = {}
            if #sym.owners > 0 then
                family = require("kotlin-lite.impl").type_family({ name = sym.owners[1].name, pkg = sym.pkg }, E)
            end
        end
        return family
    end

    local dir = jars.is_jar(decl.filename) and search.root() or reach(decl.filename, sym.vis)
    local hits = E.run({ "-w", "-e", word }, { dir })
    local files, order = {}, {}
    local function add(path)
        if not files[path] then
            files[path] = true
            order[#order + 1] = path
        end
    end
    if not jars.is_jar(decl.filename) then add(decl.filename) end
    for _, it in ipairs(hits) do add(it.filename) end

    for i, path in ipairs(order) do
        local lines = path == ctx.path and ctx.sc.lines or file_lines(path)
        local sc = path == ctx.path and ctx.sc or scope.scan(lines)
        local visible = true
        if #sym.owners == 0 and path ~= decl.filename then
            local hdr = imports.parse(vim.list_slice(lines, 1, 200))
            visible = hdr.package == sym.pkg or imports.rank(hdr, word, sym.pkg) < imports.NONE
        end
        for l = 1, #lines do
            for _, c in ipairs(occurrences(sc, word, l)) do
                local keep
                if i > SCAN_BUDGET then
                    keep = true
                elseif not visible then
                    local r = resolve.receiver(sc, l, c)
                    keep = r and r.kind == "chain" and table.concat(r.segs, ".") == sym.pkg
                else
                    keep = means(S, path, sc, l, c)
                end
                if keep then out[#out + 1] = qf_item(path, sc, l, c, word) end
            end
        end
    end
    return { items = out, sym = sym, decl = decl }
end

return M
