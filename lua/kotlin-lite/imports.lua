-- Kotlin name resolution from a file's header: rank declaration candidates the
-- way the compiler picks them -- explicit import, same package, star import,
-- default imports -- so gd / K can skip the picker when the header decides.

local M = {}

-- rank of a candidate nothing in the header points at
M.NONE = 5

-- packages every Kotlin file sees without importing them
local DEFAULT = {
    ["kotlin"] = true, ["kotlin.annotation"] = true, ["kotlin.collections"] = true,
    ["kotlin.comparisons"] = true, ["kotlin.io"] = true, ["kotlin.ranges"] = true,
    ["kotlin.sequences"] = true, ["kotlin.text"] = true, ["kotlin.jvm"] = true,
    ["kotlin.js"] = true, ["java.lang"] = true,
}
M.DEFAULT = DEFAULT

-- package declared in `file` (reads only the head of the file)
function M.package_of(file)
    local ok, lines = pcall(vim.fn.readfile, file, "", 40)
    if not ok then return nil end
    for _, l in ipairs(lines) do
        local pkg = l:match("^%s*package%s+([%w_.]+)")
        if pkg then return pkg end
    end
    return nil
end

--- Header of a buffer / file.
--- @return { package:string?, explicit:table<string,string>, aliases:table<string,{name:string,qualifier:string}>, wildcards:string[] }
---   explicit: imported simple name -> qualifier ("Flow" -> "kotlinx.coroutines.flow")
function M.parse(lines)
    local ctx = { explicit = {}, aliases = {}, wildcards = {} }
    for _, l in ipairs(lines) do
        local pkg = l:match("^%s*package%s+([%w_.]+)")
        if pkg then ctx.package = pkg end
        local path, alias = l:match("^%s*import%s+([%w_.]+)%s+as%s+([%w_]+)")
        path = path or l:match("^%s*import%s+([%w_.]+)")
        if path then
            if path:sub(-1) == "." then
                ctx.wildcards[#ctx.wildcards + 1] = path:sub(1, -2)
            else
                local q, name = path:match("^(.*)%.([%w_]+)$")
                if q then
                    if alias then
                        ctx.aliases[alias] = { name = name, qualifier = q }
                    else
                        ctx.explicit[name] = q
                    end
                end
            end
        elseif l:match("^%s*[%a@]") and not l:match("^%s*package") and not l:match("^%s*@file") then
            break -- first declaration: the header is over
        end
    end
    return ctx
end

-- `pkg` hosts something reachable through `qualifier`: the package itself or,
-- for nested classes (a.b.Outer), one of its prefixes
local function within(pkg, qualifier)
    return pkg == qualifier or qualifier:sub(1, #pkg + 1) == pkg .. "."
end
M.within = within

--- How directly the header points at a declaration of `word` living in `pkg`:
--- 1 explicit import, 2 same package, 3 star import, 4 default import, NONE otherwise.
function M.rank(ctx, word, pkg)
    if not pkg then return M.NONE end
    local q = ctx.explicit[word]
    if q then return within(pkg, q) and 1 or M.NONE end -- an explicit import shadows the rest
    if pkg == ctx.package then return 2 end
    for _, w in ipairs(ctx.wildcards) do
        if within(pkg, w) then return 3 end
    end
    if DEFAULT[pkg] then return 4 end
    return M.NONE
end

--- Set `it.rank` on every rg item; returns the best (lowest) rank.
function M.rank_items(ctx, word, items)
    local pkgs, best = {}, M.NONE
    for _, it in ipairs(items) do
        local pkg = pkgs[it.filename]
        if pkg == nil then
            pkg = M.package_of(it.filename) or false
            pkgs[it.filename] = pkg
        end
        it.rank = M.rank(ctx, word, pkg or nil)
        if it.rank < best then best = it.rank end
    end
    return best
end

-- import line under the cursor -> { name, qualifier } of the segment's class
-- (else of the imported decl), or { wildcard = "a.b" }
function M.import_target(line, word)
    local path, alias = line:match("^%s*import%s+([%w_.]+)%s+as%s+([%w_]+)")
    path = path or line:match("^%s*import%s+([%w_.]+)")
    if not path then return nil end
    if path:sub(-1) == "." then return { wildcard = path:sub(1, -2) } end
    local segs = vim.split(path, ".", { plain = true })
    local whole = { name = segs[#segs], qualifier = table.concat(segs, ".", 1, #segs - 1) }
    if alias == word then return whole end
    -- class segments start at the first capital
    local first = #segs
    for i, seg in ipairs(segs) do
        if seg:match("^%u") then first = i break end
    end
    for i = #segs, first, -1 do
        if segs[i] == word then
            return { name = word, qualifier = table.concat(segs, ".", 1, i - 1) }
        end
    end
    return whole
end
--- Header of the current buffer.
function M.current()
    return M.parse(vim.api.nvim_buf_get_lines(0, 0, 200, false))
end

return M
