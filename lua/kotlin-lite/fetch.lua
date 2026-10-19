-- Sources on demand: gd on a class of a library whose sources aren't
-- extracted finds its -sources.jar in the gradle / maven cache, else asks
-- gradle for it like IntelliJ's "Download Sources" does: an init script finds
-- the classpath jar holding the class and resolves `group:artifact:version:
-- sources`. The jar is extracted, then gd runs again.

local jars = require("kotlin-lite.jars")
local search = require("kotlin-lite.search")

local M = {}

-- packages of the platform: on no gradle classpath
local PLATFORM = { java = true, javax = true, jdk = true, sun = true, android = true, dalvik = true }

-- per target (class entry, else package), this session: a message (or false) when there is nothing to fetch
local failed = {}

function M.reset()
    failed = {}
end

--- import qualifier + name -> { pkg, dir = "a/b/", entry = "a/b/Outer.class"? },
--- nil when there's nothing gradle could download. No entry for a top-level
--- fun / val / CONSTANT: it is in some FileKt.class, the package has to do
function M.target(qualifier, word)
    if not qualifier then return nil end
    local segs, cls = {}, nil
    for seg in qualifier:gmatch("[^.]+") do
        if seg:match("^%u") then
            cls = seg
            break
        end
        segs[#segs + 1] = seg
    end
    if #segs == 0 or PLATFORM[segs[1]] then return nil end
    local t = { pkg = table.concat(segs, "."), dir = table.concat(segs, "/") .. "/" }
    local name = cls or word
    if name:match("^%u") and not (#name > 1 and name:match("^[%u%d_]+$")) then
        t.entry = t.dir .. name .. ".class"
    end
    return t
end

--- gradle output -> { sources = { path }, nosources = "g:a:v"?, noclass = true? }
function M.parse(lines)
    local out, seen, noclass = { sources = {} }, {}, false
    for _, l in ipairs(lines) do
        local path = l:match("^KL%-SOURCES (.+)$")
        if path and not seen[path] then
            seen[path] = true
            out.sources[#out.sources + 1] = path
        end
        out.nosources = out.nosources or l:match("^KL%-NOSOURCES (%S+)")
        if l:match("^KL%-NOCLASS") then noclass = true end
    end
    -- every project answers: one that knows the class wins
    if noclass and #out.sources == 0 and not out.nosources then out.noclass = true end
    return out
end

-------------------------------------------------------------------
-- the gradle cache
-------------------------------------------------------------------

local function zip_has_pkg(jar, dir)
    local res = vim.system({ "unzip", "-Z1", jar }, { text = true }):wait()
    for entry in (res.stdout or ""):gmatch("[^\n]+") do
        local d, ext = entry:match("^(.*)/[^/]+%.(%a+)$")
        if (ext == "kt" or ext == "java") and (d == dir or d:sub(-#dir - 1) == "/" .. dir) then
            return true
        end
    end
    return false
end

--- -sources.jars under `roots` (gradle files-2.1 / maven layout) of the group
--- the package is in, holding the package: the newest of each artifact
function M.cached(pkg, roots)
    local segs = vim.split(pkg, ".", { plain = true })
    local found = {}
    for _, root in ipairs(roots) do
        -- deepest group that is a prefix of the package (two segments at least)
        for i = #segs, 2, -1 do
            local prefix = vim.list_slice(segs, 1, i)
            local dir
            for _, d in ipairs({ table.concat(prefix, "."), table.concat(prefix, "/") }) do
                if vim.fn.isdirectory(root .. "/" .. d) == 1 then dir = root .. "/" .. d break end
            end
            if dir then
                vim.list_extend(found, vim.fn.globpath(dir, "**/*-sources.jar", false, true))
                break
            end
        end
    end
    local pkg_path = table.concat(segs, "/")
    found = vim.tbl_filter(function(j) return zip_has_pkg(j, pkg_path) end, found)
    return vim.tbl_map(function(e) return e.jar end, jars._latest_by_artifact(found))
end

local function roots()
    local out = {}
    for _, p in ipairs(require("kotlin-lite.config").options.jar_search_roots) do
        p = vim.fn.expand(p)
        if vim.fn.isdirectory(p) == 1 then out[#out + 1] = p end
    end
    return out
end

-- the project declares the package itself (a typo, generated code): no download
local function in_project(pkg)
    local re = "^package\\s+" .. pkg:gsub("%.", "\\.") .. "\\s*;?\\s*$"
    local res = vim.system({ "rg", "-q", "-g", "*.kt", "-g", "*.java", re, search.root() }):wait()
    return res.code == 0
end

-------------------------------------------------------------------
-- gradle
-------------------------------------------------------------------

-- the module's compile classpaths -> the jar / aar with the class (else every
-- one with a class in the package) -> its sources
local INIT_SCRIPT = [[
// kotlin-lite: the -sources.jar of the classpath jar / aar holding -Pkl.class,
// else of each one with a class right in -Pkl.pkg
import java.util.zip.ZipFile
import java.util.zip.ZipInputStream
import org.gradle.api.artifacts.component.ModuleComponentIdentifier

// entry names of a jar, of the classes.jar in an aar
def klEntries = { File f ->
    def names = []
    def z = new ZipFile(f)
    try {
        if (f.name.endsWith(".aar")) {
            def inner = z.getEntry("classes.jar")
            if (inner != null) {
                def zin = new ZipInputStream(z.getInputStream(inner))
                for (def e = zin.nextEntry; e != null; e = zin.nextEntry) names << e.name
            }
        } else {
            z.entries().each { names << it.name }
        }
    } finally {
        z.close()
    }
    names
}

allprojects {
    def p = project
    tasks.register("klSources") {
        def cls = p.findProperty("kl.class")
        def pkg = p.findProperty("kl.pkg")
        doLast {
            def seen = [] as Set
            def hit = null
            def inPkg = [:]
            for (c in p.configurations.toList()) {
                if (hit != null) break
                if (!c.canBeResolved || !c.name.toLowerCase().endsWith("compileclasspath")) continue
                def arts
                try {
                    arts = c.incoming.artifactView { lenient = true }.artifacts.artifacts
                } catch (ignored) {
                    continue
                }
                for (a in arts) {
                    def id = a.id.componentIdentifier
                    def f = a.file
                    if (!(id instanceof ModuleComponentIdentifier)) continue
                    if (!(f.name.endsWith(".jar") || f.name.endsWith(".aar")) || !seen.add(f)) continue
                    def names
                    try {
                        names = klEntries(f)
                    } catch (ignored) {
                        continue
                    }
                    if (cls != null && names.contains(cls)) { hit = id; break }
                    if (pkg != null && names.any {
                        it.startsWith(pkg) && it.endsWith(".class") && it.indexOf("/", pkg.length()) < 0
                    }) inPkg["${id.group}:${id.module}:${id.version}"] = id
                }
            }
            def ids = hit != null ? [hit] : inPkg.values().toList()
            if (ids.isEmpty()) {
                println "KL-NOCLASS"
                return
            }
            for (id in ids) {
                def gav = "${id.group}:${id.module}:${id.version}"
                def dep = p.dependencies.create("${gav}:sources@jar")
                def files = p.configurations.detachedConfiguration(dep)
                    .incoming.artifactView { lenient = true }.files.files
                if (files.isEmpty()) println "KL-NOSOURCES ${gav}"
                else files.each { println "KL-SOURCES ${it}" }
            }
        }
    }
}
]]

local function init_script()
    local path = vim.fn.stdpath("cache") .. "/kotlin-lite-sources-init.gradle"
    pcall(vim.fn.writefile, vim.split(INIT_SCRIPT, "\n"), path)
    return path
end

--- argv asking gradle in `root` for the sources of target `t`, from the
--- classpaths of `module` (":app"; nil: the root project)
function M.command(root, t, module)
    local bin = vim.fn.executable(root .. "/gradlew") == 1 and root .. "/gradlew" or "gradle"
    local cmd = {
        bin, "-q", "--no-configuration-cache", "--init-script", init_script(),
        (module or "") .. ":klSources", "-Pkl.pkg=" .. t.dir,
    }
    if t.entry then cmd[#cmd + 1] = "-Pkl.class=" .. t.entry end
    return cmd
end

--- cb(stdout lines, exit code, stderr) on the main loop (stubbed in tests)
function M.run(cmd, cwd, cb)
    local ok, err = pcall(vim.system, cmd, { cwd = cwd, text = true }, function(res)
        vim.schedule(function()
            cb(vim.split(res.stdout or "", "\n", { trimempty = true }), res.code, res.stderr or "")
        end)
    end)
    if not ok then cb({}, -1, tostring(err)) end
end

local function gradle_root(file)
    return vim.fs.root(file, { "settings.gradle.kts", "settings.gradle", "gradlew" })
end

-------------------------------------------------------------------
-- entry point
-------------------------------------------------------------------

-- extract the jars not extracted yet -> cb(any extracted)
local function extract(paths, cb)
    paths = vim.tbl_filter(function(p) return not jars.is_extracted(p) end, paths)
    local left, any = #paths, false
    if left == 0 then return cb(false) end
    for _, p in ipairs(paths) do
        jars.extract_jar(p, true, function(ok)
            any = any or ok
            left = left - 1
            if left == 0 then cb(any) end
        end)
    end
end

--- Make the sources of target `t` (see M.target) searchable for `file`.
--- cb(ok, msg?): ok = new sources extracted; msg = why there are none
function M.sources_for(t, file, cb)
    local key = t.entry or t.dir
    if failed[key] ~= nil then return cb(false, failed[key] or nil) end
    if in_project(t.pkg) then return cb(false) end
    local cached = vim.tbl_filter(function(p) return not jars.is_extracted(p) end, M.cached(t.pkg, roots()))
    if #cached > 0 then return extract(cached, cb) end

    local root = gradle_root(file)
    if not root then return cb(false) end
    vim.notify("kotlin-lite: downloading sources for " .. t.pkg .. " ...", vim.log.levels.INFO)
    local module = require("kotlin-lite.runner").module_of(root, file)
    M.run(M.command(root, t, module), root, function(lines, code, stderr)
        local r = M.parse(lines)
        if #r.sources > 0 then
            return extract(r.sources, function(ok) cb(ok) end)
        end
        if r.nosources or r.noclass then
            failed[key] = r.nosources and ("no sources published for " .. r.nosources) or false
            return cb(false, failed[key] or nil)
        end
        -- gradle itself failed (offline, broken build): worth another try later
        local why = vim.trim(stderr):match("[^\n]*$")
        cb(false, "gradle failed (exit " .. tostring(code) .. ")" .. (why ~= "" and ": " .. why or ""))
    end)
end

return M
