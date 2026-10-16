-- Lexical structure of a file: comments / strings masked, `{}` blocks with
-- kind and head, `()` groups -- enough to tell where a declaration is visible.

local M = {}

M.KEYWORDS = {}
for w in ([[package import class interface object fun val var typealias constructor init
    if else when for while do try catch finally return break continue throw is in as
    this super null true false by where get set companion data enum sealed open abstract
    override private protected internal public lateinit const inline suspend operator
    infix vararg noinline crossinline reified expect actual inner value annotation out]]):gmatch("%S+") do
    M.KEYWORDS[w] = true
end

-- position key: (line, 0-based col) as one comparable number
local BIG = 1e6
local function key(l, c) return l * BIG + c end
M.key = key

function M.unkey(k)
    return math.floor(k / BIG), k % BIG
end

-------------------------------------------------------------------
-- masking
-------------------------------------------------------------------

--- Comments and literal contents blanked (columns kept); templates stay code.
function M.mask(lines)
    local out = {}
    local state, depth = "code", 0 -- depth: nested /* */ level
    local tmpl = {} -- open `${`: { kind = "str"|"raw", braces = n }
    for li, line in ipairs(lines) do
        local buf, i, n = {}, 1, #line
        local function keep(a, b) if b >= a then buf[#buf + 1] = line:sub(a, b) end end
        local function blank(a, b) if b >= a then buf[#buf + 1] = string.rep(" ", b - a + 1) end end
        while i <= n do
            if state == "code" then
                local j = line:find("[\"'/{}]", i)
                if not j then keep(i, n) break end
                keep(i, j - 1)
                local c = line:sub(j, j)
                if c == "/" then
                    local nx = line:sub(j + 1, j + 1)
                    if nx == "/" then
                        blank(j, n)
                        i = n + 1
                    elseif nx == "*" then
                        blank(j, j + 1)
                        state, depth, i = "block", 1, j + 2
                    else
                        keep(j, j)
                        i = j + 1
                    end
                elseif c == '"' then
                    if line:sub(j, j + 2) == '"""' then
                        blank(j, j + 2)
                        state, i = "raw", j + 3
                    else
                        blank(j, j)
                        state, i = "str", j + 1
                    end
                elseif c == "'" then
                    local e = line:find("'", j + (line:sub(j + 1, j + 1) == "\\" and 3 or 2), true)
                    if e then blank(j, e) i = e + 1 else keep(j, j) i = j + 1 end
                elseif c == "{" then
                    local t = tmpl[#tmpl]
                    if t then t.braces = t.braces + 1 end
                    keep(j, j)
                    i = j + 1
                else -- "}"
                    local t = tmpl[#tmpl]
                    if t and t.braces == 0 then
                        blank(j, j)
                        tmpl[#tmpl] = nil
                        state = t.kind
                    else
                        if t then t.braces = t.braces - 1 end
                        keep(j, j)
                    end
                    i = j + 1
                end
            elseif state == "block" then
                local a = line:find("/*", i, true)
                local b = line:find("*/", i, true)
                if not a and not b then blank(i, n) break end
                if a and (not b or a < b) then
                    blank(i, a + 1)
                    depth, i = depth + 1, a + 2
                else
                    blank(i, b + 1)
                    depth, i = depth - 1, b + 2
                    if depth == 0 then state = "code" end
                end
            else -- "str" / "raw"
                local j = line:find(state == "str" and '[\\"$]' or '["$]', i)
                if not j then blank(i, n) break end
                local c = line:sub(j, j)
                if c == "\\" then
                    blank(i, j + 1)
                    i = j + 2
                elseif c == '"' then
                    if state == "str" then
                        blank(i, j)
                        state, i = "code", j + 1
                    elseif line:sub(j, j + 2) == '"""' then
                        local e = j + 2
                        while line:sub(e + 1, e + 1) == '"' do e = e + 1 end
                        blank(i, e)
                        state, i = "code", e + 1
                    else
                        blank(i, j)
                        i = j + 1
                    end
                else -- "$"
                    if line:sub(j + 1, j + 1) == "{" then
                        blank(i, j + 1)
                        tmpl[#tmpl + 1] = { kind = state, braces = 0 }
                        state, i = "code", j + 2
                    else
                        local id = line:match("^[%a_][%w_]*", j + 1)
                        blank(i, j)
                        if id then keep(j + 1, j + #id) end
                        i = j + 1 + (id and #id or 0)
                    end
                end
            end
        end
        if state == "str" then state = "code" end -- "..." never spans lines
        out[li] = table.concat(buf)
    end
    return out
end

-------------------------------------------------------------------
-- blocks
-------------------------------------------------------------------

local function slice(mask, from, to)
    local l1, c1 = math.floor(from / BIG), from % BIG
    local l2, c2 = math.floor(to / BIG), to % BIG
    if l1 == l2 then return (mask[l1] or ""):sub(c1 + 1, c2) end
    local parts = { (mask[l1] or ""):sub(c1 + 1) }
    for l = l1 + 1, l2 - 1 do parts[#parts + 1] = mask[l] end
    parts[#parts + 1] = (mask[l2] or ""):sub(1, c2)
    return table.concat(parts, "\n")
end

local CTRL_TAIL = {
    "%f[%w_]if%s*%b()%s*$", "%f[%w_]else%s*$", "%f[%w_]when%s*%b()%s*$", "%f[%w_]when%s*$",
    "%f[%w_]for%s*%b()%s*$", "%f[%w_]while%s*%b()%s*$", "%f[%w_]do%s*$", "%f[%w_]try%s*$",
    "%f[%w_]catch%s*%b()%s*$", "%f[%w_]finally%s*$", "%->%s*$",
}

-- block kind from its head: type | fun | ctrl | lambda
local function classify_block(b)
    local head = b.head:gsub("::%s*class", "")
    if head:find("%f[%w_]class%f[^%w_]") or head:find("%f[%w_]interface%f[^%w_]")
        or head:find("%f[%w_]object%f[^%w_]") then
        b.kind = "type"
        local h = require("kotlin-lite.impl").parse_header(vim.trim(head):gsub("%s+", " "))
        if h then
            b.name, b.supers, b.companion = h.name, h.supers, h.mods.companion
        end
        return
    end
    local after_fun = head:match("%f[%w_]fun%f[^%w_](.*)$")
    local expression_body = after_fun and after_fun:gsub("%b()", ""):find("=", 1, true)
    if (after_fun and not expression_body) or head:match("^%s*init%s*$")
        or head:find("%f[%w_]constructor%f[^%w_]") or head:find("%f[%w_][gs]et%s*%b()%s*$") then
        b.kind = "fun"
        local sig = head:match("%f[%w_]fun%s+(.-)%s*%(")
        if sig then
            sig = sig:gsub("^%b<>%s*", "")
            local recv = sig:match("^(.-)%.[%w_]+$")
            if recv then b.ext = recv:gsub("%b<>", ""):match("([%w_]+)%??$") end
        end
        return
    end
    for _, p in ipairs(CTRL_TAIL) do
        if head:find(p) then b.kind = "ctrl" return end
    end
    b.kind = "lambda"
    b.callee = head:match("([%w_]+)%s*%b()%s*$") or head:match("([%w_]+)%s*%b<>%s*$")
        or head:match("([%w_]+)%s*$")
end

--- -> { lines, mask, root, blocks, parens }; block: { open, close, head,
--- kind, depth, parent, name?, supers?, ext?, callee? }
function M.scan(lines)
    local mask = M.mask(lines)
    local root = { kind = "file", open = 0, close = math.huge, depth = 0, head = "", pdepth = 0 }
    local blocks, parens = { root }, {}
    local stack, pstack = { root }, {}
    local head_start, prev_cont = key(1, 0), false

    for l, m in ipairs(mask) do
        local first = m:find("%S")
        local cur = stack[#stack]
        if first then
            local cont = m:match("^%s*[:,%)%.%?]") or m:match("^%s*where%f[^%w_]") or m:match("^%s*%->")
            if #pstack == cur.pdepth and not prev_cont and not cont then
                head_start = key(l, first - 1)
            end
        end
        local i = 1
        while true do
            local j = m:find("[{}();]", i)
            if not j then break end
            local ch, k = m:sub(j, j), key(l, j - 1)
            if ch == "(" then
                pstack[#pstack + 1] = { open = k, block = stack[#stack] }
            elseif ch == ")" then
                local p = table.remove(pstack)
                if p then
                    p.close = k
                    parens[#parens + 1] = p
                end
            elseif ch == "{" then
                local b = {
                    open = k, head_start = head_start, parent = stack[#stack],
                    depth = #stack, pdepth = #pstack,
                }
                b.head = slice(mask, head_start, k)
                classify_block(b)
                blocks[#blocks + 1] = b
                stack[#stack + 1] = b
                head_start = k + 1
            elseif ch == "}" then
                if #stack > 1 then
                    local b = table.remove(stack)
                    b.close = k
                end
                head_start = k + 1
            elseif #pstack == stack[#stack].pdepth then -- ";" ends a statement
                head_start = k + 1
            end
            i = j + 1
        end
        if first then prev_cont = m:match("[,(:=%.]%s*$") ~= nil end
    end
    for _, b in ipairs(stack) do b.close = b.close or math.huge end
    for _, p in ipairs(pstack) do
        p.close = math.huge
        parens[#parens + 1] = p
    end
    return { lines = lines, mask = mask, root = root, blocks = blocks, parens = parens }
end

function M.innermost(sc, p)
    local best = sc.root
    for _, b in ipairs(sc.blocks) do
        if b.open < p and p < b.close and b.depth > best.depth then best = b end
    end
    return best
end

-- end of the statement at line `l` (deeper-indented lines continue it)
local function statement_end(sc, l)
    local ind = #(sc.lines[l] or ""):match("^%s*")
    local e = l
    for i = l + 1, #sc.lines do
        local s = sc.mask[i]
        if s:find("%S") then
            if #s:match("^%s*") <= ind then break end
            e = i
        end
    end
    return key(e, BIG - 1)
end

--- Where the decl at (lnum, col) is visible -> { lnum, col, kind, from, to,
--- depth, scope, member_of? }
function M.place(sc, lnum, col, kind)
    local p = key(lnum, col)
    local B = M.innermost(sc, p)
    local d = { lnum = lnum, col = col, kind = kind }

    -- param list / for / catch around the decl (not destructuring)
    local group
    for _, g in ipairs(sc.parens) do
        if g.block == B and g.open < p and p < g.close and (not group or g.open < group.open) then
            group = g
        end
    end
    if group then
        local gl, gc = math.floor(group.open / BIG), group.open % BIG
        if sc.mask[gl]:sub(1, gc):match("%f[%w_]va[lr]%s*$") then group = nil end
    end

    if group then
        local S
        for _, b in ipairs(sc.blocks) do
            if b.open > group.close and b.parent == B and b.head_start <= p then
                S = b
                break
            end
        end
        local cl, cc = math.floor(group.close / BIG), group.close % BIG
        if S then
            d.from, d.to, d.scope, d.depth = p, S.close, S, S.depth
            local before = sc.mask[lnum]:sub(1, col)
            if S.kind == "type" and before:match("%f[%w_]va[lr]%s+$") then d.member_of = S end
        elseif sc.mask[cl]:sub(cc + 2):match("^%s*%->") then -- { (a, b) -> }
            d.from, d.to, d.scope, d.depth = p, B.close, B, B.depth
        else -- expression body: fun f(x: Int) = x, for (i in r) stmt
            d.from, d.to, d.scope, d.depth = p, statement_end(sc, math.floor(group.open / BIG)), B, B.depth + 1
        end
        return d
    end

    d.scope, d.depth = B, B.depth
    if B.kind == "type" or B == sc.root then
        d.from, d.to = B.open, B.close
        if B.kind == "type" then d.member_of = B end
    else
        d.from, d.to = p, B.close
    end
    return d
end

local search -- lazy: circular require

--- Placed declarations of `word` in `sc` (memoized on `sc`).
function M.decls(sc, word)
    sc.decl_memo = sc.decl_memo or {}
    if sc.decl_memo[word] then return sc.decl_memo[word] end
    search = search or require("kotlin-lite.search")
    -- one-line patterns: only lines holding the word can match
    local lnums, subset = {}, {}
    for l, m in ipairs(sc.mask) do
        if m:find(word, 1, true) then
            lnums[#lnums + 1] = l
            subset[#subset + 1] = sc.lines[l]
        end
    end
    local out, seen = {}, {}
    for _, pat in ipairs(#subset > 0 and search.buffer_decl_patterns(word) or {}) do
        local ok, found = pcall(vim.fn.matchstrlist, subset, pat.re)
        if ok then
            for _, m in ipairs(found) do
                local lnum = lnums[m.idx + 1]
                local k = key(lnum, m.byteidx)
                if not seen[k] and (sc.mask[lnum] or ""):sub(m.byteidx + 1, m.byteidx + #word) == word then
                    seen[k] = true
                    local d = M.place(sc, lnum, m.byteidx, pat.kind)
                    if pat.kind ~= "lambda" or d.scope.kind == "lambda" then out[#out + 1] = d end
                end
            end
        end
    end
    table.sort(out, function(a, b) return key(a.lnum, a.col) < key(b.lnum, b.col) end)
    sc.decl_memo[word] = out
    return out
end

--- The decl visible at `p`: innermost scope, then nearest before (`skip` ignored).
function M.visible(decls, p, skip)
    local best
    for _, d in ipairs(decls) do
        local k = key(d.lnum, d.col)
        if k ~= skip and d.from <= p and p <= d.to then
            if not best or d.depth > best.depth
                or (d.depth == best.depth and k <= p and k > key(best.lnum, best.col)) then
                best = d
            end
        end
    end
    return best
end

--- Type blocks named in `names`, plus their companions.
function M.type_blocks(sc, names)
    local set = {}
    for _, b in ipairs(sc.blocks) do
        if b.kind == "type" and b.name and names[b.name] then set[b] = true end
    end
    for _, b in ipairs(sc.blocks) do
        if b.kind == "type" and b.companion and set[b.parent] then set[b] = true end
    end
    return set
end

--- Enclosing blocks of `p`, innermost first.
function M.enclosing(sc, p)
    local out, b = {}, M.innermost(sc, p)
    while b and b ~= sc.root do
        out[#out + 1] = b
        b = b.parent
    end
    return out
end

return M
