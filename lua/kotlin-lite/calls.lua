-- Incoming calls: the usages of a declaration, each named after the
-- function (or property) it is in.

local scope = require("kotlin-lite.scope")

local M = {}

-- the name of `fun name(`, `fun <T> Recv<T>.name(`, ``fun `a name`(``
local function declared_fun(s, prefix)
    s = s:gsub("%b<>", "")
    return s:match(prefix .. "%f[%w_]fun%s+[^(`]-(`[^`]+`)%s*%(")
        or s:match(prefix .. "%f[%w_]fun%s+[^(]-([%w_]+)%s*%(")
end

local function fun_name(head)
    if head:match("^%s*init%s*$") then return "init" end
    if head:find("%f[%w_]constructor%f[^%w_]") then return "constructor" end
    return declared_fun(head, "") or head:match("%f[%w_]([gs]et)%s*%b()%s*$")
end

local function declares_type(line)
    line = line:gsub("::%s*class", "")
    return line:find("%f[%w_]class%f[^%w_]") or line:find("%f[%w_]interface%f[^%w_]")
        or line:find("%f[%w_]object%f[^%w_]")
end

--- `fun x` / `val x` starting on a line of a class or file body
function M.member_on(line)
    line = line:gsub("%b<>", "")
    return declared_fun(line, "^[%w_%s@]-")
        or line:match("^[%w_%s@]-%f[%w_]va[lr]%s+[%w_.]-([%w_]+)%f[^%w_.]")
end

-- the member of `b` (a class or the file) whose declaration line `l` belongs to
local function member_at(sc, b, l)
    local ind = #sc.mask[l]:match("^%s*")
    for k = l, scope.unkey(b.open) + 1, -1 do
        local m = sc.mask[k]
        if m:find("%S") and #m:match("^%s*") <= ind then
            local name = M.member_on(m)
            if name or declares_type(m) then return name end
            ind = #m:match("^%s*")
        end
    end
end

local function type_name(b)
    return b.name or (b.companion and "Companion")
end

--- { "Outer", "Inner", "fun" } for the code at line `l`, col `c` of `sc`
function M.path(sc, l, c, java)
    local names, fun, done, from = {}, nil, false, l
    for _, b in ipairs(scope.enclosing(sc, scope.key(l, c))) do
        if b.kind == "type" then
            if not done then fun, done = member_at(sc, b, from), true end
            local name = type_name(b)
            if name then table.insert(names, 1, name) end
        elseif not done and b.kind == "fun" then
            fun = fun_name(b.head)
            done = fun ~= nil
        elseif not done and b.kind == "lambda" then
            if java then
                fun = b.callee
                done = fun ~= nil
            else
                from = scope.unkey(b.open)
            end
        end
    end
    if not done then fun = member_at(sc, sc.root, from) end
    names[#names + 1] = fun
    return names
end

--- { "Outer", "Inner" }: the classes around position `p` (a scope key)
function M.types(sc, p)
    local names = {}
    for _, b in ipairs(scope.enclosing(sc, p)) do
        local name = b.kind == "type" and type_name(b)
        if name then table.insert(names, 1, name) end
    end
    return names
end

--- "Outer.Inner.fun" for the code at line `l`, col `c` of `sc`
function M.caller(sc, l, c, java)
    return table.concat(M.path(sc, l, c, java), ".")
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
