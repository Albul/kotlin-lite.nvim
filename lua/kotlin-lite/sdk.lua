-- Platform sources, searched next to the extracted jars.
--
-- Android code (a module with the android plugin; in KMP its android* source
-- sets): sources/android-<compileSdk> of the Android SDK, else the nearest
-- installed level; then the compileSdk platform's android-stubs-src.jar
-- (signatures only) for what those sources lack. The stubs start every
-- member at column 0, so they are extracted reindented by braces.
--
-- JVM code (a module without android; in KMP its jvm* / desktop* source
-- sets): lib/src.zip of the JDK the toolchain asks for, else $JAVA_HOME, else
-- the newest installed; java.* / javax.* of `jdk_modules`, extracted once.

local M = {}

local function cfg()
    return require("kotlin-lite.config").options
end

local by_path = {} -- file -> its SDK dirs
-- SDK dir -> { level, want = compileSdk / toolchain, stubs?, api = the stubs dir, jdk? }
local used = {}
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

-- KMP source set -> its platform; nil: shared by several
local function sset_platform(sset)
    if sset:match("^android") then return "android" end
    if sset:match("^jvm") or sset:match("^desktop") then return "jvm" end
    for _, p in ipairs({ "ios", "macos", "tvos", "watchos", "apple", "native", "linux", "mingw" }) do
        if sset:sub(1, #p) == p then return "native" end
    end
    if sset:match("^js") or sset:match("^wasm") or sset:match("^web") then return "web" end
    return nil
end

--- platform the code in `path` compiles for: "android" (a module applying
--- the android plugin), "jvm" (any other module, a file outside gradle), in
--- KMP by source set: "android", "jvm", "native", "web", nil (common code)
function M.platform(path)
    local build = build_file(path)
    local text = build and table.concat(read(build) or {}, "\n") or ""
    -- kotlin multiplatform (not compose multiplatform): by source set
    local low = text:lower()
    local kmp = low:find("kotlinmultiplatform", 1, true) or low:find('kotlin("multiplatform")', 1, true)
        or low:find("kotlin.multiplatform", 1, true)
    if kmp then
        local sset = path:match("/src/([%w]+)/")
        return sset and sset_platform(sset) or nil
    end
    local android = text:find("com%.android") or text:find("plugins%.android")
        or text:find("android%w*Library") or text:find("android%w*Application")
        or text:find("androidTarget%s*%(") or text:find("%f[%w]android%s*{")
    return android and "android" or "jvm"
end

--- code that compiles against android.jar
function M.is_android(path)
    return M.platform(path) == "android"
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
-- the JDK
-------------------------------------------------------------------

-- where JDKs are installed: each child a JDK home
M.JDK_ROOTS = { "~/.sdkman/candidates/java", "/usr/lib/jvm", "/Library/Java/JavaVirtualMachines" }

--- the Java version a build script compiles for, nil when it doesn't say
function M._parse_toolchain(lines)
    local text = table.concat(lines, "\n")
    local n = text:match("jvmToolchain%s*%(%s*(%d+)") or text:match("JavaLanguageVersion%.of%s*%(%s*(%d+)")
        or text:match("JvmTarget%.JVM_1_(%d+)") or text:match("JvmTarget%.JVM_(%d+)")
        or text:match("JavaVersion%.VERSION_1_(%d+)") or text:match("JavaVersion%.VERSION_(%d+)")
        or text:match("jvmTarget%s*=%s*\"1%.(%d+)\"") or text:match("jvmTarget%s*=%s*\"(%d+)\"")
    return n and tonumber(n) or nil
end

--- the toolchain of the module of `path`, else of the root project
function M.toolchain(path)
    local build = build_file(path)
    local n = build and M._parse_toolchain(read(build) or {})
    if n then return n end
    local settings = find_up(path, { "settings.gradle.kts", "settings.gradle" })
    local root = settings and vim.fs.dirname(settings)
    for _, f in ipairs(root and { root .. "/build.gradle.kts", root .. "/build.gradle" } or {}) do
        n = M._parse_toolchain(read(f) or {})
        if n then return n end
    end
    return nil
end

-- { home, version = "21.0.3", major = 21 } of a JDK home with sources, else nil
local function jdk_at(home)
    if not (home and vim.fn.filereadable(home .. "/lib/src.zip") == 1) then return nil end
    local version
    for _, l in ipairs(read(home .. "/release") or {}) do
        version = version or l:match('^JAVA_VERSION="([^"]+)"')
    end
    if not version then return nil end
    local major = tonumber(version:match("^1%.(%d+)") or version:match("^(%d+)"))
    return { home = vim.fn.resolve(home), version = version, major = major }
end

-- the installed JDKs with sources; $JAVA_HOME first
local function jdks()
    local out, seen = {}, {}
    local function add(home)
        local j = home and jdk_at(vim.fn.expand(home))
        if j and not seen[j.home] then
            seen[j.home] = true
            out[#out + 1] = j
        end
    end
    add(vim.env.JAVA_HOME)
    for _, root in ipairs(M.JDK_ROOTS) do
        root = vim.fn.expand(root)
        if is_dir(root) then
            for name, t in vim.fs.dir(root) do
                if t == "directory" or t == "link" then
                    add(root .. "/" .. name)
                    add(root .. "/" .. name .. "/Contents/Home")
                end
            end
        end
    end
    local java = vim.fn.exepath("java")
    if java ~= "" then add(vim.fs.dirname(vim.fs.dirname(vim.fn.resolve(java)))) end
    return out
end

--- the JDK for code in `path`: the `jdk` option's home; else the one the
--- toolchain asks for (else the nearest newer, else the nearest older);
--- else $JAVA_HOME; else the newest. { home, version, major, want? } or nil
function M.jdk(path)
    local opt = cfg().jdk
    if opt == false then return nil end
    if type(opt) == "string" then return jdk_at(vim.fn.expand(opt)) end
    local all = jdks()
    if #all == 0 then return nil end
    local want = M.toolchain(path)
    local pick
    if want then
        local newer, older
        for _, j in ipairs(all) do
            if j.major == want and not pick then pick = j end
            if j.major > want and (not newer or j.major < newer.major) then newer = j end
            if j.major < want and (not older or j.major > older.major) then older = j end
        end
        pick = pick or newer or older
    elseif vim.env.JAVA_HOME and all[1].home == vim.fn.resolve(vim.fn.expand(vim.env.JAVA_HOME)) then
        pick = all[1]
    else
        for _, j in ipairs(all) do
            if not pick or j.major > pick.major then pick = j end
        end
    end
    return vim.tbl_extend("force", pick, { want = want })
end

-- java.* / javax.* of `jdk_modules` from the JDK's src.zip, in the jar cache -> dir
local function jdk_dir(j)
    local dir = cfg().cache_dir .. "/jdk-" .. j.version
    local mods = cfg().jdk_modules
    local marker = dir .. "/.sdk"
    if vim.fn.filereadable(marker) == 1 and (read(marker) or {})[1] == table.concat(mods, ",") then return dir end
    local tmp = dir .. ".tmp"
    vim.fn.delete(tmp, "rf")
    vim.fn.mkdir(tmp, "p")
    local cmd = { "unzip", "-o", "-q", j.home .. "/lib/src.zip" }
    for _, m in ipairs(mods) do vim.list_extend(cmd, { m .. "/java/*", m .. "/javax/*" }) end
    vim.list_extend(cmd, { "-d", tmp })
    local res = vim.system(cmd):wait()
    -- 11: some pattern matched nothing (a module without javax.*)
    if res.code ~= 0 and res.code ~= 11 then
        vim.fn.delete(tmp, "rf")
        return nil
    end
    vim.fn.delete(dir, "rf")
    vim.fn.rename(tmp, dir)
    vim.fn.writefile({ "jdk-" .. j.version }, dir .. "/.jarname")
    vim.fn.writefile({ table.concat(mods, ",") }, marker)
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

-- the JDK's dir for JVM code in `path` -> out
local function jdk_dirs(path, out)
    local j = M.jdk(path)
    local dir = j and jdk_dir(j)
    if dir then
        if not used[dir] then readonly(dir) end
        used[dir] = { level = j.major, want = j.want, jdk = true }
        out[#out + 1] = dir
    end
    return out
end

--- platform dirs for code in `path`, best first: android code the SDK's
--- sources and stubs, JVM code the JDK; {} for other code or no SDK / JDK
function M.dirs(path)
    if not path or path == "" then return {} end
    if by_path[path] then return by_path[path] end
    local out = {}
    by_path[path] = out
    local platform = M.platform(path)
    if platform == "jvm" then return jdk_dirs(path, out) end
    local root = platform == "android" and M.root(path)
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
        if not used[stubs] then readonly(stubs) end
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
M.owner = owner

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

-- Java types Kotlin maps to its own (kotlin.String, kotlin.Any, kotlin.collections.List,
-- ...): their members aren't Kotlin's, the Kotlin types are the declarations
local MAPPED = {}
for _, f in ipairs({
    "java/lang/Object", "java/lang/String", "java/lang/CharSequence", "java/lang/Throwable",
    "java/lang/Comparable", "java/lang/Enum", "java/lang/Cloneable", "java/lang/Iterable",
    "java/lang/Number", "java/lang/Boolean", "java/lang/Byte", "java/lang/Short", "java/lang/Integer",
    "java/lang/Long", "java/lang/Character", "java/lang/Float", "java/lang/Double",
    "java/lang/annotation/Annotation", "java/util/Collection", "java/util/List", "java/util/Set",
    "java/util/Map", "java/util/Iterator", "java/util/ListIterator",
}) do MAPPED[f .. ".java"] = true end

-- the stubs are the public API: a sources file they lack is internal / @hide
local function is_public(info, rel)
    if not info.api then return true end
    local f = info.api .. "/" .. rel
    if public[f] == nil then public[f] = vim.uv.fs_stat(f) ~= nil end
    return public[f]
end

-- path below the dir, from the package root (the JDK's has a module dir first)
local function rel_of(file, dir, info)
    local rel = file:sub(#dir + 2)
    return info.jdk and rel:gsub("^[^/]+/", "", 1) or rel
end

-- public API, not a type Kotlin maps to its own
local function in_api(info, rel)
    return not MAPPED[rel] and (info.stubs or is_public(info, rel))
end

--- SDK hits narrowed: a top-level one only from a package the file imports
--- (or names, or java.lang); none outside the public API, none of a type
--- Kotlin maps to its own. (A stub where the sources have that file goes in
--- defs.latest_only.)
function M.filter(hits, hdr, opts)
    if not next(used) then return hits end
    local allowed = { ["java.lang"] = true }
    for _, q in pairs(hdr.explicit or {}) do allowed[pkg_part(q) or ""] = true end
    for _, a in pairs(hdr.aliases or {}) do allowed[pkg_part(a.qualifier) or ""] = true end
    for _, w in ipairs(hdr.wildcards or {}) do allowed[pkg_part(w) or ""] = true end
    for _, k in ipairs({ "qualifier", "pkg", "soft_qualifier" }) do
        if opts[k] then allowed[pkg_part(opts[k]) or ""] = true end
    end

    return vim.tbl_filter(function(it)
        local dir, info = owner(it.filename)
        if not dir then return true end
        local rel = rel_of(it.filename, dir, info)
        if not in_api(info, rel) then return false end
        if (it.indent or 0) > 0 then return true end
        return allowed[(vim.fs.dirname(rel):gsub("/", "."))] == true
    end, hits)
end

--- SDK hits narrowed to the public API, of any package (what can be imported)
function M.api_only(hits)
    if not next(used) then return hits end
    return vim.tbl_filter(function(it)
        local dir, info = owner(it.filename)
        return not dir or in_api(info, rel_of(it.filename, dir, info))
    end, hits)
end

-------------------------------------------------------------------
-- presentation
-------------------------------------------------------------------

--- "[android-35] android/os/Build.java", "[jdk-21] java/lang/Thread.java"
--- for an SDK file, else nil
function M.label(file)
    local dir, info = owner(file)
    if not dir then return nil end
    if info.jdk then return ("[jdk-%d] %s"):format(info.level, rel_of(file, dir, info)) end
    return ("[android-%d%s] %s"):format(info.level, info.stubs and " stubs" or "", file:sub(#dir + 2))
end

--- once per session: the file jumped into isn't the compileSdk sources
function M.notice(file)
    local dir, info = owner(file)
    if not dir or not info.want or (info.level == info.want and not info.stubs) then return end
    local key = dir .. ":" .. info.want
    if noted[key] then return end
    noted[key] = true
    if info.jdk then
        vim.notify(("kotlin-lite: JDK %d sources (toolchain %d): no JDK %d with lib/src.zip found, `jdk` sets its home")
            :format(info.level, info.want, info.want), vim.log.levels.INFO)
        return
    end
    local what = info.stubs and ("API %d stubs, signatures only"):format(info.level)
        or ("API %d sources"):format(info.level)
    vim.notify(("kotlin-lite: %s (compileSdk %d): `sdkmanager \"sources;android-%d\"` installs the exact sources")
        :format(what, info.want, info.want), vim.log.levels.INFO)
end

return M
