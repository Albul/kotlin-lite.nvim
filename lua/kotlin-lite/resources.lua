-- R.<type>.<name> / Res.<type>.<name>: the R and Res classes are generated,
-- so their fields lead straight to res/ and composeResources/.

local search = require("kotlin-lite.search")

local M = { kind = "a resource", home = "the xml" }

local VALUE_TAGS = {
    string = { "string" },
    plurals = { "plurals" },
    array = { "string-array", "integer-array", "array" },
    color = { "color" },
    dimen = { "dimen" },
    bool = { "bool" },
    integer = { "integer" },
    fraction = { "fraction" },
    style = { "style" },
    attr = { "attr" },
    styleable = { "declare-styleable" },
}

local FILE_DIRS = {
    drawable = true, mipmap = true, layout = true, raw = true, font = true, menu = true,
    xml = true, anim = true, animator = true, navigation = true, transition = true,
    interpolator = true, color = true,
}

local ROOTS = { "res", "composeResources" }

--- `ctx` on the name of R.<type>.<name> -> { class, type, name }, else nil
function M.ref(ctx)
    local r = ctx.code and not ctx.call and ctx.recv
    if not r or r.kind ~= "chain" or r.ctor then return nil end
    local n = #r.segs
    local class, type = r.segs[n - 1], r.segs[n]
    if class ~= "R" and class ~= "Res" then return nil end
    if n == 3 and r.segs[1] == "android" then return nil end
    if not VALUE_TAGS[type] and not FILE_DIRS[type] and type ~= "id" then return nil end
    return { class = class, type = type, name = ctx.word }
end

-- in values/: `.` in a name becomes `_` in R
local function name_re(name)
    return (name:gsub("_", "[._]"))
end

local function globs(dirs, file)
    local out = {}
    for _, root in ipairs(ROOTS) do
        for _, d in ipairs(dirs) do
            out[#out + 1] = "**/" .. root .. "/" .. d .. "/" .. file
        end
    end
    return out
end

local function grep(E, re, g)
    local args = { "-e", re }
    for _, x in ipairs(g) do vim.list_extend(args, { "-g", x }) end
    return E.run(args, { search.root() })
end

local function qualifier(it)
    return vim.fs.basename(vim.fs.dirname(it.filename))
end

local function find_items(ref, E)
    local items = {}
    local tags = VALUE_TAGS[ref.type]
    if tags then
        local re = ('<(%s)\\b[^>]*\\bname="%s"'):format(table.concat(tags, "|"), name_re(ref.name))
        vim.list_extend(items, grep(E, re, globs({ "values", "values-*" }, "*.xml")))
    end
    if FILE_DIRS[ref.type] then
        for _, it in ipairs(E.files(globs({ ref.type, ref.type .. "-*" }, ref.name .. ".*"), { search.root() })) do
            it.file = true
            items[#items + 1] = it
        end
    end
    if ref.type == "id" then
        vim.list_extend(items, grep(E, '@\\+id/' .. ref.name .. '"', globs({ "*" }, "*.xml")))
    end
    for _, it in ipairs(items) do
        it.qualifier = qualifier(it)
        it.default = not it.qualifier:find("-", 1, true)
    end
    table.sort(items, function(a, b)
        if a.default ~= b.default then return a.default end
        if a.qualifier ~= b.qualifier then return a.qualifier < b.qualifier end
        return a.filename < b.filename
    end)
    return items
end

-- K: the value (or the file) per qualifier
local function listing(label, items)
    local rows = {}
    for _, it in ipairs(items) do
        local value = it.file and vim.fn.fnamemodify(it.filename, ":.") or it.text:match(">(.-)</") or it.text
        rows[#rows + 1] = { it.qualifier, value }
    end
    return { title = label, rows = rows }
end

--- -> nil when nothing is found, else a resolve result with `resources`
--- (every match, default qualifier first)
function M.resolve(ref, E)
    local items = find_items(ref, E)
    if #items == 0 then return nil end
    local label = ref.class .. "." .. ref.type .. "." .. ref.name
    local res = { resources = items, label = label, listing = listing(label, items) }
    local cands = vim.tbl_filter(function(it) return it.default end, items)
    if ref.type == "id" or #cands == 0 then cands = items end
    if #cands == 1 then
        res.jump = cands[1]
    else
        for _, it in ipairs(cands) do it.rank = 0 end
        res.pool, res.word = cands, label
    end
    return res
end

--- gu: R.<type>.<name> in Kotlin / Java, @<type>/<name> in Android xml
function M.usages(ref, E)
    local root = { search.root() }
    local code = E.start({ "-e", ("\\b%s\\.%s\\.%s\\b"):format(ref.class, ref.type, ref.name) }, root)
    local xml
    if ref.class == "R" then
        local at = ref.type == "id" and "@\\+?id/" or ("@" .. ref.type .. "/")
        xml = E.start({
            "-e", at .. name_re(ref.name) .. "\\b",
            "-g", "**/res/**/*.xml", "-g", "**/AndroidManifest.xml",
        }, root)
    end
    local out = {}
    for _, h in ipairs({ code, xml }) do
        for _, it in ipairs(E.await(h)) do out[#out + 1] = search.at_word(it, ref.name) end
    end
    return out
end

return M
