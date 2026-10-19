-- *-sources.jar discovery/extraction. Extracted trees feed project search and
-- are opened read-only.

local M = {}

-- extracted source trees, refreshed by scan_cache() (first scan on first use)
local jar_dirs = {}
local scanned = false
local infos = {}       -- dir -> M.info
local by_project = {}  -- path -> project_dirs, until the next scan
local backfilled = false

local function cfg()
    return require("kotlin-lite.config").options
end

function M.jar_dirs()
    if not scanned then M.scan_cache() end
    return jar_dirs
end

function M.jar_label(dir)
    local ok, lines = pcall(vim.fn.readfile, dir .. "/.jarname")
    if ok and lines[1] then return lines[1] end
    return vim.fn.fnamemodify(dir, ":t")
end

function M.scan_cache()
    local cache_dir = cfg().cache_dir
    jar_dirs, scanned, infos, by_project = {}, true, {}, {}
    if vim.fn.isdirectory(cache_dir) == 0 then return end
    local legacy = false
    for name, t in vim.fs.dir(cache_dir) do
        if t == "directory" then
            local dir = cache_dir .. "/" .. name
            if vim.fn.filereadable(dir .. "/.extracted") == 1 then
                table.insert(jar_dirs, dir)
                -- named by the jar path's hash, its origin not kept yet
                legacy = legacy or (#name == 64 and vim.fn.filereadable(dir .. "/.jarpath") == 0)
            end
        end
    end
    table.sort(jar_dirs)
    if legacy and not backfilled then
        backfilled = true
        vim.schedule(function() M.backfill() end)
    end
end

-- library sources: an extracted jar, the Android SDK
function M.is_jar(file)
    return file:find(cfg().cache_dir, 1, true) == 1 or require("kotlin-lite.sdk").owns(file)
end

-------------------------------------------------------------------
-- version parsing (artifact vs version, latest wins)
-------------------------------------------------------------------

-- classifiers published next to the sources: not part of the version
local CLASSIFIERS = { "samples" }

-- "kotlin-stdlib-jdk8-2.2.10-sources.jar" -> "kotlin-stdlib-jdk8", "2.2.10"
-- "ui-1.11.2-samples-sources.jar" -> "ui", "1.11.2", "samples"
-- version starts at the first hyphen segment that begins with a digit.
local function parse_nv(basename)
    local base = basename:gsub("%-sources%.jar$", "")
    local classifier
    for _, c in ipairs(CLASSIFIERS) do
        if base:sub(-#c - 1) == "-" .. c then
            base, classifier = base:sub(1, -#c - 2), c
        end
    end
    local parts = vim.split(base, "-", { plain = true })
    for i, p in ipairs(parts) do
        if p:match("^%d") then
            return table.concat(parts, "-", 1, i - 1), table.concat(parts, "-", i), classifier
        end
    end
    return base, "", classifier
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

--- group of the jar at `path` (gradle files-2.1 / maven layout), nil if unknown
function M._group_of(path, artifact, version)
    local segs = vim.split(path, "/", { plain = true })
    for i = #segs - 1, 3, -1 do
        if segs[i] == version and segs[i - 1] == artifact then
            for k = 1, i - 2 do
                if segs[k] == "repository" then return table.concat(segs, ".", k + 1, i - 2) end
            end
            return segs[i - 2] ~= "" and segs[i - 2] or nil
        end
    end
    return nil
end

-- pinned version of { group, artifact } in `pins` (see M._parse_pins); with
-- no group known by the artifact name alone
local function pinned(pins, group, artifact)
    if not pins then return nil end
    local kotlin = group == "org.jetbrains.kotlin" or (not group and artifact:match("^kotlin%-") ~= nil)
    return (group and pins[group .. ":" .. artifact] or pins[":" .. artifact])
        or (kotlin and pins["org.jetbrains.kotlin:*"]) or nil
end

-- keep one version of each artifact (group:name:classifier): the pinned one
-- if present, else the newest. returns a list of { jar, base, artifact, version }
local function latest_by_artifact(jar_paths, pins)
    local best = {}
    for _, j in ipairs(jar_paths) do
        local base = vim.fn.fnamemodify(j, ":t")
        local artifact, version, classifier = parse_nv(base)
        local group = M._group_of(j, artifact, version)
        local key = (group or "") .. ":" .. artifact .. ":" .. (classifier or "")
        local cur, pin = best[key], pinned(pins, group, artifact)
        if not cur or (pin and version == pin) or (cur.version ~= pin and ver_lt(cur.version, version)) then
            best[key] = { jar = j, base = base, artifact = artifact, version = version, classifier = classifier }
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

local function extract_dir(jar_path)
    return cfg().cache_dir .. "/" .. vim.fn.sha256(jar_path)
end

function M.is_extracted(jar_path)
    return vim.fn.filereadable(extract_dir(jar_path) .. "/.extracted") == 1
end

-- on_done(ok) once the tree is searchable (ok = false: unzip failed)
function M.extract_jar(jar_path, quiet, on_done)
    on_done = on_done or function() end
    local dir = extract_dir(jar_path)
    if M.is_extracted(jar_path) then
        if not quiet then vim.notify("kotlin-lite: already extracted", vim.log.levels.INFO) end
        return on_done(true)
    end
    vim.fn.mkdir(dir, "p")
    local jar_name = vim.fn.fnamemodify(jar_path, ":t")
    if not quiet then
        vim.notify("kotlin-lite: extracting " .. jar_name .. " ...", vim.log.levels.INFO)
    end
    vim.system({ "unzip", "-o", "-q", jar_path, "-d", dir }, {}, function(res)
        vim.schedule(function()
            -- the cache cleared meanwhile
            if res.code == 0 and vim.fn.isdirectory(dir) == 0 then return on_done(false) end
            if res.code == 0 then
                vim.fn.writefile({ jar_name }, dir .. "/.jarname")
                vim.fn.writefile({ jar_path }, dir .. "/.jarpath")
                vim.fn.writefile({}, dir .. "/.extracted")
                M.scan_cache()
                if not quiet then
                    vim.notify("kotlin-lite: " .. jar_name .. " is ready", vim.log.levels.INFO)
                end
                on_done(true)
            else
                vim.fn.delete(dir, "rf")
                if not quiet then
                    vim.notify("kotlin-lite: unzip failed for " .. jar_name, vim.log.levels.ERROR)
                end
                on_done(false)
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
    for _, d in ipairs(M.jar_dirs()) do done[M.jar_label(d)] = true end
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
-- the project's libraries: one version each, the variants that fit
-------------------------------------------------------------------

-- the common package prefix of the shallowest source files in `dir`: tells
-- apart libraries of one artifact name (androidx.core:core vs
-- com.google.zxing:core), the same for every version, whether the jar is
-- still in the caches or not
local function root_package(dir)
    -- the shallowest source files: breadth first, two whole levels with some
    local files, level, levels = {}, { dir }, 0
    while levels < 2 and #level > 0 and #level < 400 do
        local had = #files
        local next_level = {}
        for _, d in ipairs(level) do
            for name, t in vim.fs.dir(d) do
                if t == "directory" and name ~= "META-INF" then
                    next_level[#next_level + 1] = d .. "/" .. name
                elseif t == "file" and (name:match("%.kt$") or name:match("%.java$")) and #files - had < 20 then
                    files[#files + 1] = d .. "/" .. name
                end
            end
        end
        level = next_level
        if #files > had then levels = levels + 1 end
    end
    local common
    for _, f in ipairs(files) do
        local ok, lines = pcall(vim.fn.readfile, f, "", 40)
        for _, l in ipairs(ok and lines or {}) do
            local pkg = l:match("^%s*package%s+([%w_.]+)")
            if pkg then
                if not common then
                    common = vim.split(pkg, ".", { plain = true })
                else
                    local segs = vim.split(pkg, ".", { plain = true })
                    local n = 0
                    while n < #common and common[n + 1] == segs[n + 1] do n = n + 1 end
                    common = vim.list_slice(common, 1, n)
                end
                break
            end
        end
    end
    return common and #common > 0 and table.concat(common, ".") or nil
end

--- { dir, base, artifact, version, classifier?, group?, id? } of an
--- extracted dir. group: from the jar's path (.jarpath), when known. id: the
--- library ("androidx.core:core:" + classifier) by its sources' root package,
--- without sources by its group, else nil: dirs of one id are versions of
--- one library
function M.info(dir)
    local i = infos[dir]
    if i then return i end
    local base = M.jar_label(dir)
    local artifact, version, classifier = parse_nv(base)
    local ok, lines = pcall(vim.fn.readfile, dir .. "/.jarpath")
    local path = ok and lines[1] or nil
    local pkg = root_package(dir)
    local group = path and path ~= "" and M._group_of(path, artifact, version) or nil
    -- no sources (a -ktx shell, an aggregate): by the group, when known
    local lib = pkg or (group and "@" .. group)
    i = { dir = dir, base = base, artifact = artifact, version = version, classifier = classifier,
        group = group, id = lib and (lib .. ":" .. artifact .. ":" .. (classifier or "")) or nil }
    infos[dir] = i
    return i
end

-- artifact suffix -> the platform of that variant
local VARIANTS = {
    { "wasm-js", "web" }, { "wasm-wasi", "web" }, { "js", "web" },
    { "android", "android" }, { "desktop", "desktop" }, { "jvm", "jvm" }, { "uikit", "native" },
}
local NATIVE = { "ios", "macos", "tvos", "watchos", "linux", "mingw", "androidnative" }

--- "ui-android" -> "ui", "android"; not a platform variant -> the name alone
function M._variant(artifact)
    for _, v in ipairs(VARIANTS) do
        if artifact:sub(-#v[1] - 1) == "-" .. v[1] then return artifact:sub(1, -#v[1] - 2), v[2] end
    end
    local base, last = artifact:match("^(.+)%-(%l[%l%d]*)$")
    for _, n in ipairs(NATIVE) do
        if last and #last > #n and last:sub(1, #n) == n then return base, "native" end
    end
    return artifact
end

-- a variant for `vp` serves code of platform `fp`: android code also gets
-- -jvm artifacts, jvm code -desktop ones
local function fits(vp, fp)
    return vp == fp or (vp == "jvm" and fp == "android") or (vp == "desktop" and fp == "jvm")
end

local function strip_q(s) return s and s:match('^"(.*)"$') or s end

--- pinned versions from version-catalog and build-script lines:
--- { ["group:artifact"] = version, ["org.jetbrains.kotlin:*"] = kotlin plugin version }
function M._parse_pins(catalog, build)
    local versions, pins, section = {}, {}, nil
    local function ver(body)
        local ref = body:match("version%.ref%s*=%s*\"([^\"]+)\"") or body:match("version%s*=%s*{%s*ref%s*=%s*\"([^\"]+)\"")
        return ref and versions[ref] or body:match("version%s*=%s*\"([^\"]+)\"")
    end
    for _, l in ipairs(catalog) do
        section = l:match("^%s*%[([%w_-]+)%]") or section
        local k, v = l:match("^%s*([%w_.%-]+)%s*=%s*(.-)%s*$")
        if k and section == "versions" then
            versions[k] = strip_q(v):match("^[^{]") and strip_q(v) or v:match("\"([^\"]+)\"")
        end
    end
    for _, l in ipairs(catalog) do
        section = l:match("^%s*%[([%w_-]+)%]") or section
        local v = l:match("^%s*[%w_.%-]+%s*=%s*(.-)%s*$")
        if v and section == "libraries" then
            local g, a, plain = (strip_q(v) or ""):match("^([%w_.%-]+):([%w_.%-]+):([^\"]+)$")
            if g then
                pins[g .. ":" .. a] = plain
            else
                local mod = v:match("module%s*=%s*\"([^\"]+)\"")
                g, a = (mod or ""):match("^(.-):(.+)$")
                g = g or v:match("group%s*=%s*\"([^\"]+)\"")
                a = a or v:match("name%s*=%s*\"([^\"]+)\"")
                if g and a and ver(v) then pins[g .. ":" .. a] = ver(v) end
            end
        elseif v and section == "plugins" and (v:match("id%s*=%s*\"([^\"]+)\"") or ""):match("^org%.jetbrains%.kotlin%.") then
            pins["org.jetbrains.kotlin:*"] = ver(v) or pins["org.jetbrains.kotlin:*"]
        end
    end
    for _, l in ipairs(build) do
        for g, a, v in l:gmatch("\"([%w_.%-]+):([%w_.%-]+):([%w_.%-]+)\"") do pins[g .. ":" .. a] = v end
        local kv = l:match("kotlin%(\"[%w-]+\"%)%s+version%s+\"([^\"]+)\"")
            or l:match("id%(\"org%.jetbrains%.kotlin%.[%w.-]+\"%)%s+version%s+\"([^\"]+)\"")
        if kv then pins["org.jetbrains.kotlin:*"] = kv end
    end
    -- by the artifact name alone too: for jars of a guessed group
    for k, v in pairs(vim.deepcopy(pins)) do
        local a = k:match("^[^:]+:(.+)$")
        if a and a ~= "*" then pins[":" .. a] = v end
    end
    return pins
end

local function read_lines(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines or {}
end

-- the gradle project of `path`: the dir of its settings script
local function project_root(path)
    local settings = vim.fs.find({ "settings.gradle.kts", "settings.gradle" },
        { upward = true, path = vim.fs.dirname(path), limit = 1 })[1]
    return settings and vim.fs.dirname(settings) or nil
end

-- pins of the gradle project of `path`: its catalog, the root and module build scripts
local function project_pins(path)
    local root = project_root(path)
    if not root then return {} end
    local build = {}
    for _, f in ipairs({ root .. "/build.gradle.kts", root .. "/build.gradle" }) do vim.list_extend(build, read_lines(f)) end
    local mod = vim.fs.find({ "build.gradle.kts", "build.gradle" }, { upward = true, path = vim.fs.dirname(path), limit = 1 })[1]
    if mod and vim.fs.dirname(mod) ~= root then vim.list_extend(build, read_lines(mod)) end
    return M._parse_pins(read_lines(root .. "/gradle/libs.versions.toml"), build)
end
M._project_pins = project_pins

-------------------------------------------------------------------
-- the project's classpath, as :KotlinSourcesSync got it from gradle
-------------------------------------------------------------------

local function classpath_file(root)
    return cfg().cache_dir .. "/.classpath/" .. vim.fn.sha256(root)
end

--- the -sources.jars of the compile classpaths of the project at `root`,
--- nil before its first sync
function M.classpath(root)
    local ok, lines = pcall(vim.fn.readfile, classpath_file(root))
    return ok and lines or nil
end

--- seconds since the epoch of the last sync of `root`, nil if never
function M.synced_at(root)
    local st = vim.uv.fs_stat(classpath_file(root))
    return st and st.mtime.sec or nil
end

--- the classpath of `root` is `jars` (replace), else gets `jars` too (a
--- library added to the build since the sync; nothing before a first sync).
--- -> any jar new to it
function M.record_classpath(root, list, replace)
    local cur = M.classpath(root)
    if not cur and not replace then return false end
    cur = replace and {} or cur
    local seen, added = {}, false
    for _, j in ipairs(cur) do seen[j] = true end
    for _, j in ipairs(list) do
        if not seen[j] then
            seen[j], added = true, true
            cur[#cur + 1] = j
        end
    end
    if added or replace then
        table.sort(cur)
        vim.fn.mkdir(vim.fs.dirname(classpath_file(root)), "p")
        vim.fn.writefile(cur, classpath_file(root))
        by_project = {}
    end
    return added
end

--- is the jar on the classpath of `root`? (true before a first sync)
function M.on_classpath(root, jar)
    local cp = M.classpath(root)
    return not cp or vim.tbl_contains(cp, jar)
end

--- extracted dirs for code in `path`: after a sync only those of the
--- project's classpath, else every one; of each library (group:artifact:
--- classifier) the version the build pins, else the newest; of platform
--- variants those fitting the file's platform (common code: only when the
--- common artifact is missing). A dir without sources to tell its group by
--- is never merged.
function M.project_dirs(path)
    path = path or ""
    if by_project[path] then return by_project[path] end
    local all = M.jar_dirs()
    local pins = path ~= "" and project_pins(path) or {}
    local root = path ~= "" and project_root(path) or nil
    local cp = root and M.classpath(root)
    if cp then
        -- a dir is named by its jar's path: the dirs of older extractions too
        local on = {}
        for _, j in ipairs(cp) do on[extract_dir(j)] = true end
        all = vim.tbl_filter(function(d) return on[d] end, all)
    end
    local fp = false -- no file: every variant
    if path ~= "" then fp = require("kotlin-lite.sdk").platform(path) end

    local best, order = {}, {}
    for _, dir in ipairs(all) do
        local i = M.info(dir)
        local key = i.id or dir
        local cur, pin = best[key], pinned(pins, i.group, i.artifact)
        if not cur then
            order[#order + 1] = key
            best[key] = i
        elseif (pin and i.version == pin) or (cur.version ~= pin and ver_lt(cur.version, i.version)) then
            best[key] = i
        end
    end
    local common = {}
    for _, key in ipairs(order) do
        local i = best[key]
        if select(2, M._variant(i.artifact)) == nil then common[i.artifact] = true end
    end
    local out = {}
    for _, key in ipairs(order) do
        local i = best[key]
        local base, vp = M._variant(i.artifact)
        local keep = not vp or fp == false or (fp == nil and not common[base]) or (fp and fits(vp, fp))
        if keep then out[#out + 1] = i.dir end
    end
    by_project[path] = out
    return out
end

--- extracted dirs without a .jarpath (extracted before it was kept): find
--- their jar under the search roots by name, matched by the dir's hash.
--- Unmatched ones get an empty .jarpath: unknown origin. -> cb()
function M.backfill(cb)
    cb = cb or function() end
    M.scan_cache()
    local legacy = {}
    for _, dir in ipairs(M.jar_dirs()) do
        if #vim.fs.basename(dir) == 64 and vim.fn.filereadable(dir .. "/.jarpath") == 0 then
            legacy[M.jar_label(dir)] = true
        end
    end
    if not next(legacy) then return cb() end
    find_source_jars(function(found)
        for _, j in ipairs(found or {}) do
            local dir = extract_dir(j)
            if legacy[vim.fn.fnamemodify(j, ":t")] and vim.fn.filereadable(dir .. "/.extracted") == 1 then
                vim.fn.writefile({ j }, dir .. "/.jarpath")
            end
        end
        for _, dir in ipairs(M.jar_dirs()) do
            if #vim.fs.basename(dir) == 64 and vim.fn.filereadable(dir .. "/.jarpath") == 0 then
                vim.fn.writefile({}, dir .. "/.jarpath")
            end
        end
        M.scan_cache()
        cb()
    end)
end

function M.clear()
    vim.fn.delete(cfg().cache_dir, "rf")
    M.scan_cache()
    vim.notify("kotlin-lite: jar cache cleared", vim.log.levels.INFO)
end

-- mark cache files read-only (cheap: no disk access)
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
end

return M
