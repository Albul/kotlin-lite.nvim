-- *-sources.jar discovery/extraction. Extracted trees feed project search and
-- are opened read-only.

local M = {}

-- extracted source trees, refreshed by scan_cache()
local jar_dirs = {}

local function cfg()
    return require("kotlin-lite.config").options
end

function M.jar_dirs()
    return jar_dirs
end

function M.jar_label(dir)
    local ok, lines = pcall(vim.fn.readfile, dir .. "/.jarname")
    if ok and lines[1] then return lines[1] end
    return vim.fn.fnamemodify(dir, ":t")
end

function M.scan_cache()
    local cache_dir = cfg().cache_dir
    jar_dirs = {}
    if vim.fn.isdirectory(cache_dir) == 0 then return end
    for name, t in vim.fs.dir(cache_dir) do
        if t == "directory" then
            local dir = cache_dir .. "/" .. name
            if vim.fn.filereadable(dir .. "/.extracted") == 1 then
                table.insert(jar_dirs, dir)
            end
        end
    end
end

function M.is_jar(file)
    return file:find(cfg().cache_dir, 1, true) == 1
end

-------------------------------------------------------------------
-- version parsing (artifact vs version, latest wins)
-------------------------------------------------------------------

-- "kotlin-stdlib-jdk8-2.2.10-sources.jar" -> "kotlin-stdlib-jdk8", "2.2.10"
-- version starts at the first hyphen segment that begins with a digit.
local function parse_nv(basename)
    local base = basename:gsub("%-sources%.jar$", "")
    local parts = vim.split(base, "-", { plain = true })
    for i, p in ipairs(parts) do
        if p:match("^%d") then
            return table.concat(parts, "-", 1, i - 1), table.concat(parts, "-", i)
        end
    end
    return base, ""
end
M._parse_nv = parse_nv

-- a < b ? numeric-dotted compare; a release beats its own pre-release
local function ver_lt(a, b)
    local function key(v)
        local core, pre = v:match("^([%d.]*)(.*)$")
        local nums = {}
        for n in (core or ""):gmatch("%d+") do nums[#nums + 1] = tonumber(n) end
        return nums, (pre ~= "" and pre or nil)
    end
    local an, ap = key(a)
    local bn, bp = key(b)
    for i = 1, math.max(#an, #bn) do
        local x, y = an[i] or 0, bn[i] or 0
        if x ~= y then return x < y end
    end
    if ap == bp then return false end
    if ap == nil then return false end -- a is a release -> not older
    if bp == nil then return true end  -- a is a pre-release, b is a release
    return ap < bp
end
M._ver_lt = ver_lt

-- keep only the newest version of each artifact.
-- returns a list of { jar, base, artifact, version }
local function latest_by_artifact(jar_paths)
    local best = {}
    for _, j in ipairs(jar_paths) do
        local base = vim.fn.fnamemodify(j, ":t")
        local artifact, version = parse_nv(base)
        local cur = best[artifact]
        if not cur or ver_lt(cur.version, version) then
            best[artifact] = { jar = j, base = base, artifact = artifact, version = version }
        end
    end
    local list = {}
    for _, e in pairs(best) do list[#list + 1] = e end
    return list
end
M._latest_by_artifact = latest_by_artifact

-------------------------------------------------------------------
-- extraction
-------------------------------------------------------------------

function M.extract_jar(jar_path, quiet)
    local dir = cfg().cache_dir .. "/" .. vim.fn.sha256(jar_path)
    if vim.fn.filereadable(dir .. "/.extracted") == 1 then
        if not quiet then vim.notify("kotlin-lite: already extracted", vim.log.levels.INFO) end
        return
    end
    vim.fn.mkdir(dir, "p")
    local jar_name = vim.fn.fnamemodify(jar_path, ":t")
    if not quiet then
        vim.notify("kotlin-lite: extracting " .. jar_name .. " ...", vim.log.levels.INFO)
    end
    vim.system({ "unzip", "-o", "-q", jar_path, "-d", dir }, {}, function(res)
        vim.schedule(function()
            if res.code == 0 then
                vim.fn.writefile({ jar_name }, dir .. "/.jarname")
                vim.fn.writefile({}, dir .. "/.extracted")
                M.scan_cache()
                if not quiet then
                    vim.notify("kotlin-lite: " .. jar_name .. " is ready", vim.log.levels.INFO)
                end
            else
                vim.fn.delete(dir, "rf")
                if not quiet then
                    vim.notify("kotlin-lite: unzip failed for " .. jar_name, vim.log.levels.ERROR)
                end
            end
        end)
    end)
end

-- existing directories from `jar_search_roots`
local function search_roots()
    local roots = {}
    for _, p in ipairs(cfg().jar_search_roots) do
        p = vim.fn.expand(p)
        if vim.fn.isdirectory(p) == 1 then roots[#roots + 1] = p end
    end
    return roots
end

-- find every *-sources.jar under the search roots (async)
local function find_source_jars(cb)
    local roots = search_roots()
    if #roots == 0 then
        cb(nil)
        return
    end
    local cmd = { "find" }
    vim.list_extend(cmd, roots)
    vim.list_extend(cmd, { "-type", "f", "-name", "*-sources.jar" })
    vim.system(cmd, { text = true }, function(res)
        vim.schedule(function()
            cb(vim.split(res.stdout or "", "\n", { trimempty = true }))
        end)
    end)
end

-- basenames already extracted
local function extracted_set()
    local done = {}
    for _, d in ipairs(jar_dirs) do done[M.jar_label(d)] = true end
    return done
end

-------------------------------------------------------------------
-- picker (:KotlinSources / <leader>ks)
-------------------------------------------------------------------

function M.pick_sources_jar()
    find_source_jars(function(jars)
        if jars == nil then
            vim.notify("kotlin-lite: no jar search roots found", vim.log.levels.WARN)
            return
        end
        if #jars == 0 then
            vim.notify("kotlin-lite: no *-sources.jar found", vim.log.levels.WARN)
            return
        end

        local done = extracted_set()
        local installed, available = {}, {}
        for _, e in ipairs(latest_by_artifact(jars)) do
            e.installed = done[e.base] or false
            table.insert(e.installed and installed or available, e)
        end
        local by_name = function(a, b) return a.base < b.base end
        table.sort(installed, by_name)
        table.sort(available, by_name)

        -- installed first, then a divider, then the rest
        local items = {}
        vim.list_extend(items, installed)
        if #installed > 0 and #available > 0 then
            items[#items + 1] = { divider = true }
        end
        vim.list_extend(items, available)

        vim.ui.select(items, {
            prompt = "Extract sources jar:",
            format_item = function(e)
                if e.divider then return string.rep("─", 44) end
                return (e.installed and "[+] " or "    ") .. e.base
            end,
        }, function(choice)
            if choice and not choice.divider then M.extract_jar(choice.jar) end
        end)
    end)
end

-------------------------------------------------------------------
-- auto-extract essentials on startup
-------------------------------------------------------------------

function M.is_android_project()
    local root = vim.fn.getcwd()
    if #vim.fs.find("AndroidManifest.xml", { path = root, type = "file", limit = 1 }) > 0 then
        return true
    end
    for _, f in ipairs({ "build.gradle.kts", "build.gradle", "settings.gradle.kts", "settings.gradle" }) do
        local ok, lines = pcall(vim.fn.readfile, root .. "/" .. f)
        if ok then
            for _, l in ipairs(lines) do
                if l:find("com.android", 1, true) then return true end
            end
        end
    end
    return false
end

-- Extract (quietly) the newest sources jar for each essential artifact that is
-- present in the cache but not yet extracted.
function M.auto_extract()
    local opts = cfg()
    if not opts.auto_extract then return end

    local wanted = {}
    for _, a in ipairs(opts.essentials.kotlin or {}) do wanted[a] = true end
    if M.is_android_project() then
        for _, a in ipairs(opts.essentials.android or {}) do wanted[a] = true end
    end
    if vim.tbl_isempty(wanted) then return end

    find_source_jars(function(jars)
        if not jars or #jars == 0 then return end
        local matched = vim.tbl_filter(function(j)
            return wanted[(parse_nv(vim.fn.fnamemodify(j, ":t")))]
        end, jars)
        local done = extracted_set()
        for _, e in ipairs(latest_by_artifact(matched)) do
            if not done[e.base] then M.extract_jar(e.jar, true) end
        end
    end)
end

function M.clear()
    vim.fn.delete(cfg().cache_dir, "rf")
    M.scan_cache()
    vim.notify("kotlin-lite: jar cache cleared", vim.log.levels.INFO)
end

-- mark cache files read-only + initial scan
function M.setup()
    vim.api.nvim_create_autocmd("BufReadPost", {
        group = vim.api.nvim_create_augroup("kotlin-lite-jar-ro", { clear = true }),
        pattern = cfg().cache_dir .. "/*",
        callback = function(ev)
            vim.bo[ev.buf].readonly = true
            vim.bo[ev.buf].modifiable = false
            vim.bo[ev.buf].swapfile = false
        end,
    })
    M.scan_cache()
end

return M
