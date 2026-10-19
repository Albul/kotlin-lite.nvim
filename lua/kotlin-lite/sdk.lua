-- Android SDK sources for android code (a module with the android plugin; in
-- KMP its android* source sets): sources/android-<compileSdk>, else the
-- nearest installed level, searched next to the extracted jars; then the
-- compileSdk platform's android-stubs-src.jar (signatures only) for what
-- those sources lack. The stubs start every member at column 0, so they are
-- extracted reindented by braces.

local M = {}

local function cfg()
    return require("kotlin-lite.config").options
end

local by_path = {} -- file -> its SDK dirs
local used = {}    -- SDK dir -> { level, want = compileSdk, stubs?, api = the stubs dir }
local noted = {}   -- notes given this session
local public = {}  -- stubs file -> it exists

function M.reset()
    by_path, used, noted, public = {}, {}, {}, {}
end

local function is_dir(p)
    return p ~= nil and p ~= "" and vim.fn.isdirectory(p) == 1
end

local function read(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines or nil
end

-- nearest `names` upward from `path` (a file or a directory)
local function find_up(path, names)
    local start = is_dir(path) and path or vim.fs.dirname(path)
    return vim.fs.find(names, { upward = true, path = start, limit = 1 })[1]
end

-------------------------------------------------------------------
-- where the SDK is, which level the code compiles against
-------------------------------------------------------------------

--- android_sdk option, $ANDROID_HOME, $ANDROID_SDK_ROOT, sdk.dir of the
--- project's local.properties, the default install dirs; nil when none
function M.root(path)
    local opt = cfg().android_sdk
    if opt == false then return nil end
    local function dir(p)
        p = p and vim.fn.expand(p)
        return is_dir(p) and p or nil
    end
    if opt then return dir(opt) end
    local found = dir(vim.env.ANDROID_HOME) or dir(vim.env.ANDROID_SDK_ROOT)
    if found then return found end
    local props = path and find_up(path, { "local.properties" })
    for _, l in ipairs(props and read(props) or {}) do
        local p = l:match("^%s*sdk%.dir%s*=%s*(.-)%s*$")
        if p then found = dir((p:gsub("\\(.)", "%1"))) end
    end
    return found or dir("~/Android/Sdk") or dir("~/Library/Android/sdk")
end

local function norm_key(s)
    return (s:lower():gsub("[%-_.]", "."))
end

--- compileSdk from build script lines, through the version catalog lines
function M._parse_compile_sdk(build, catalog)
    local text = table.concat(build, "\n")
    local n = text:match("compileSdk%s*=%s*(%d+)")
        or text:match("compileSdkVersion%s*%(?%s*(%d+)")
        or text:match("compileSdk%s*%(%s*(%d+)")
        or text:match("compileSdk%s*{[^}]-release%s*%(%s*(%d+)")
    if n then return tonumber(n) end
    local key = text:match("compileSdk%w*%s*=%s*libs%.versions%.([%w_.%-]+)%.get%(")
    if not key then return nil end
    for _, l in ipairs(catalog) do
        local k, v = l:match('^%s*([%w_.%-]+)%s*=%s*"(%d+)')
        if k and norm_key(k) == norm_key(key) then return tonumber(v) end
    end
    return nil
end

-- android-<level>[.<minor>] dirs under `dir` passing `ok` -> { [level] = path }
local function levels(dir, ok)
    local out = {}
    if not is_dir(dir) then return out end
    for name, t in vim.fs.dir(dir) do
        local n = name:match("^android%-(%d+)")
        local path = dir .. "/" .. name
        if n and t == "directory" and not out[tonumber(n)] and ok(path) then out[tonumber(n)] = path end
    end
    return out
end

local function stubs_jar(path)
    return path .. "/android-stubs-src.jar"
end

local function platforms(root)
    return levels(root .. "/platforms", function(p) return vim.fn.filereadable(stubs_jar(p)) == 1 end)
end

local function build_file(path)
    return find_up(path, { "build.gradle.kts", "build.gradle" })
end

--- the compileSdk of the module of `path`; else the newest installed platform
function M.compile_sdk(path)
    local build = build_file(path)
    local settings = find_up(path, { "settings.gradle.kts", "settings.gradle" })
    local catalog = settings and read(vim.fs.dirname(settings) .. "/gradle/libs.versions.toml") or {}
    local n = build and M._parse_compile_sdk(read(build) or {}, catalog)
    if n then return n end
    local root, best = M.root(path), nil
    for l in pairs(root and platforms(root) or {}) do best = math.max(best or l, l) end
    return best
end

--- code that compiles against android.jar: a module applying the android
--- plugin; in a KMP one only its android* source sets
function M.is_android(path)
    local build = build_file(path)
    local text = build and table.concat(read(build) or {}, "\n") or ""
    local android = text:find("com%.android") or text:find("plugins%.android")
        or text:find("android%w*Library") or text:find("android%w*Application")
        or text:find("androidTarget%s*%(") or text:find("%f[%w]android%s*{")
    if not android then return false end
    -- kotlin multiplatform (not compose multiplatform): by source set
    local low = text:lower()
    local kmp = low:find("kotlinmultiplatform", 1, true) or low:find('kotlin("multiplatform")', 1, true)
        or low:find("kotlin.multiplatform", 1, true)
    if not kmp then return true end
    local sset = path:match("/src/([%w]+)/")
    return sset ~= nil and sset:match("^android") ~= nil
end

-------------------------------------------------------------------
-- the stubs, reindented
-------------------------------------------------------------------

local B_OPEN, B_CLOSE, B_QUOTE, B_APOS = ("{"):byte(), ("}"):byte(), ('"'):byte(), ("'"):byte()
local B_SLASH, B_STAR, B_ESC = ("/"):byte(), ("*"):byte(), ("\\"):byte()

--- Java lines indented by brace depth (comments, strings and chars don't
--- count); lines inside a block comment are left as they are
function M._reindent(lines)
    local out, depth, in_block = {}, 0, false
    for i, raw in ipairs(lines) do
        local l = raw:match("^%s*(.-)%s*$")
        local start_block, start_depth = in_block, depth
        if in_block or l:find("[{}\"'/]") then
            local j, n, str = 1, #l, nil
            while j <= n do
                local c = l:byte(j)
                if in_block then
                    if c == B_STAR and l:byte(j + 1) == B_SLASH then
                        in_block = false
                        j = j + 1
                    end
                elseif str then
                    if c == B_ESC then
                        j = j + 1
                    elseif c == str then
                        str = nil
                    end
                elseif c == B_QUOTE or c == B_APOS then
                    str = c
                elseif c == B_SLASH and l:byte(j + 1) == B_SLASH then
                    break
                elseif c == B_SLASH and l:byte(j + 1) == B_STAR then
                    in_block = true
                    j = j + 1
                elseif c == B_OPEN then
                    depth = depth + 1
                elseif c == B_CLOSE then
                    depth = depth - 1
                end
                j = j + 1
            end
        end
        if start_block then
            out[i] = raw
        else
            local lead = #(l:match("^}*"))
            out[i] = l == "" and "" or string.rep("    ", math.max(start_depth - lead, 0)) .. l
        end
    end
    return out
end

-- the stubs jar of `level` extracted (reindented) into the jar cache -> dir
local function stubs_dir(platform, level)
    local dir = cfg().cache_dir .. "/android-stubs-" .. level
    if vim.fn.filereadable(dir .. "/.sdk") == 1 then return dir end
    local tmp = dir .. ".tmp"
    vim.fn.delete(tmp, "rf")
    vim.fn.mkdir(tmp, "p")
    local res = vim.system({ "unzip", "-o", "-q", stubs_jar(platform), "-d", tmp }):wait()
    if res.code ~= 0 then
        vim.fn.delete(tmp, "rf")
        return nil
    end
    for _, f in ipairs(vim.fs.find(function(name) return name:sub(-5) == ".java" end,
        { path = tmp, type = "file", limit = math.huge })) do
        local lines = read(f)
        if lines then vim.fn.writefile(M._reindent(lines), f) end
    end
    vim.fn.delete(dir, "rf")
    vim.fn.rename(tmp, dir)
    vim.fn.writefile({ "android-stubs-" .. level }, dir .. "/.jarname")
    vim.fn.writefile({}, dir .. "/.sdk")
    return dir
end

-------------------------------------------------------------------
-- the dirs to search
-------------------------------------------------------------------

-- the level `want` if present, else the nearest older, else the nearest newer
local function nearest(map, want)
    if map[want] then return want end
    local older, newer
    for l in pairs(map) do
        if l < want and (not older or l > older) then older = l end
        if l > want and (not newer or l < newer) then newer = l end
    end
    return older or newer
end

local function readonly(dir)
    vim.api.nvim_create_autocmd("BufReadPost", {
        group = vim.api.nvim_create_augroup("kotlin-lite-sdk-ro", { clear = false }),
        pattern = dir .. "/*",
        callback = function(ev)
            vim.bo[ev.buf].readonly = true
            vim.bo[ev.buf].modifiable = false
            vim.bo[ev.buf].swapfile = false
        end,
    })
end

--- SDK dirs for code in `path`, best first: the sources, the stubs; {} when
--- the code isn't android or there's no SDK
function M.dirs(path)
    if not path or path == "" then return {} end
    if by_path[path] then return by_path[path] end
    local out = {}
    by_path[path] = out
    local root = M.is_android(path) and M.root(path)
    local want = root and M.compile_sdk(path)
    if not want then return out end

    local sources = levels(root .. "/sources", function(p) return is_dir(p .. "/android") end)
    local plats = platforms(root)
    local plevel = nearest(plats, want)
    local stubs = plevel and stubs_dir(plats[plevel], plevel)
    local level = nearest(sources, want)
    if level then
        local dir = sources[level]
        if not used[dir] then readonly(dir) end
        used[dir] = { level = level, want = want, api = stubs }
        out[#out + 1] = dir
    end
    if stubs then
        used[stubs] = { level = plevel, want = want, stubs = true }
        out[#out + 1] = stubs
    end
    return out
end

-- the SDK dir `file` is in -> dir, info
local function owner(file)
    for dir, info in pairs(used) do
        if file:sub(1, #dir + 1) == dir .. "/" then return dir, info end
    end
end

function M.owns(file)
    return next(used) ~= nil and owner(file) ~= nil
end

-------------------------------------------------------------------
-- narrowing the hits
-------------------------------------------------------------------

local function pkg_part(q)
    local segs = {}
    for seg in (q or ""):gmatch("[^.]+") do
        if seg:match("^%u") then break end
        segs[#segs + 1] = seg
    end
    return #segs > 0 and table.concat(segs, ".") or nil
end

-- the stubs are the public API: a sources file they lack is internal / @hide
local function is_public(info, rel)
    if not info.api then return true end
    local f = info.api .. "/" .. rel
    if public[f] == nil then public[f] = vim.uv.fs_stat(f) ~= nil end
    return public[f]
end

--- SDK hits narrowed: a top-level one only from a package the file imports
--- (or names, or java.lang); none outside the public API; a stub only where
--- the sources lack that file
function M.filter(hits, hdr, opts)
    if not next(used) then return hits end
    local allowed = { ["java.lang"] = true }
    for _, q in pairs(hdr.explicit or {}) do allowed[pkg_part(q) or ""] = true end
    for _, a in pairs(hdr.aliases or {}) do allowed[pkg_part(a.qualifier) or ""] = true end
    for _, w in ipairs(hdr.wildcards or {}) do allowed[pkg_part(w) or ""] = true end
    for _, k in ipairs({ "qualifier", "pkg", "soft_qualifier" }) do
        if opts[k] then allowed[pkg_part(opts[k]) or ""] = true end
    end

    local in_sources = {}
    for _, it in ipairs(hits) do
        local dir, info = owner(it.filename)
        if dir and not info.stubs then in_sources[it.filename:sub(#dir + 2)] = true end
    end
    return vim.tbl_filter(function(it)
        local dir, info = owner(it.filename)
        if not dir then return true end
        local rel = it.filename:sub(#dir + 2)
        if info.stubs and in_sources[rel] then return false end
        if not info.stubs and not is_public(info, rel) then return false end
        if (it.indent or 0) > 0 then return true end
        return allowed[(vim.fs.dirname(rel):gsub("/", "."))] == true
    end, hits)
end

-------------------------------------------------------------------
-- presentation
-------------------------------------------------------------------

--- "[android-35] android/os/Build.java" for an SDK file, else nil
function M.label(file)
    local dir, info = owner(file)
    if not dir then return nil end
    return ("[android-%d%s] %s"):format(info.level, info.stubs and " stubs" or "", file:sub(#dir + 2))
end

--- once per session: the file jumped into isn't the compileSdk sources
function M.notice(file)
    local dir, info = owner(file)
    if not dir or (info.level == info.want and not info.stubs) then return end
    local key = dir .. ":" .. info.want
    if noted[key] then return end
    noted[key] = true
    local what = info.stubs and ("API %d stubs, signatures only"):format(info.level)
        or ("API %d sources"):format(info.level)
    vim.notify(("kotlin-lite: %s (compileSdk %d): `sdkmanager \"sources;android-%d\"` installs the exact sources")
        :format(what, info.want, info.want), vim.log.levels.INFO)
end

return M
