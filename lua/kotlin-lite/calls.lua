-- Incoming calls: the usages of a declaration, each named after the
-- function (or property) it is in.

local scope = require("kotlin-lite.scope")

local M = {}

-- the name of `fun name(`, `fun Recv.name(`, ``fun `a name`(``
local function declared_fun(s, prefix)
    return s:match(prefix .. "%f[%w_]fun%s+[^(`]-(`[^`]+`)%s*[(<]")
        or s:match(prefix .. "%f[%w_]fun%s+[^(]-([%w_]+)%s*[(<]")
end

local function fun_name(head)
    if head:match("^%s*init%s*$") then return "init" end
    if head:find("%f[%w_]constructor%f[^%w_]") then return "constructor" end
    return declared_fun(head, "") or head:match("%f[%w_]([gs]et)%s*%b()%s*$")
end

-- `fun x` / `val x` starting on a line of a class or file body
local function member_on(line)
    return declared_fun(line, "^[%w_%s@]-")
        or line:match("^[%w_%s@]-%f[%w_]va[lr]%s+[%w_.]-([%w_]+)%f[^%w_.]")
end

-- the member of `b` (a class or the file) whose declaration line `l` belongs to
local function member_at(sc, b, l)
    local ind = #sc.mask[l]:match("^%s*")
    for k = l, scope.unkey(b.open) + 1, -1 do
        local m = sc.mask[k]
        if m:find("%S") and #m:match("^%s*") <= ind then
            local name = member_on(m)
            if name then return name end
            ind = #m:match("^%s*")
        end
    end
end

--- "Outer.Inner.fun" for the code at line `l`, col `c` of `sc`
function M.caller(sc, l, c, java)
    local names, fun, from = {}, nil, l
    for _, b in ipairs(scope.enclosing(sc, scope.key(l, c))) do
        if b.kind == "type" then
            if not fun then fun = member_at(sc, b, from) end
            local name = b.name or (b.companion and "Companion")
            if name then table.insert(names, 1, name) end
        elseif not fun and b.kind == "fun" then
            fun = fun_name(b.head)
        elseif not fun and b.kind == "lambda" then
            if java then fun = b.callee else from = scope.unkey(b.open) end
        end
    end
    fun = fun or member_at(sc, sc.root, from)
    names[#names + 1] = fun
    return table.concat(names, ".")
end

local function is_import(it)
    return it.text:match("^import%s") ~= nil
end

local function is_decl(it, decl)
    return decl and it.filename == decl.filename and it.lnum == decl.lnum and it.col == decl.col
end

--- usages (gu items) -> the calls, `text` prefixed with the caller
function M.incoming(items, decl, sc_of)
    local out = {}
    for _, it in ipairs(items) do
        if not is_import(it) and not is_decl(it, decl) then
            local sc = sc_of(it.filename)
            local who = sc and M.caller(sc, it.lnum, it.col - 1, it.filename:match("%.java$"))
            who = (who and who ~= "") and who or vim.fs.basename(it.filename)
            out[#out + 1] = vim.tbl_extend("force", it, { text = who .. ": " .. it.text })
        end
    end
    return out
end

return M
