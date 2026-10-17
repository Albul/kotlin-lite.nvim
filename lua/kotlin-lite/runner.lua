-- Run / test the file / project in a bottom terminal split.
--
-- Gradle-first (wrapper preferred), with make / manage.py fallbacks for `run`.
-- Tests inject a gradle init script (--init-script) that forces per-test
-- PASSED/FAILED logging + a total line, then failed cases are parsed from the
-- JUnit XML results into the quickfix list. No project changes, no new deps.

local M = {}

local uv = vim.uv or vim.loop

local function cfg()
    return require("kotlin-lite.config").options
end

local function exists(p)
    return p ~= nil and uv.fs_stat(p) ~= nil
end

-- "./gradlew" (wrapper preferred) / "gradle" / nil
local function gradle_bin(root)
    if exists(root .. "/gradlew") then return "./gradlew" end
    if exists(root .. "/build.gradle.kts") or exists(root .. "/build.gradle") then return "gradle" end
    return nil
end

-- nearest ancestor that looks like a runnable project root
function M.find_root(bufnr)
    return vim.fs.root(bufnr or 0, {
        "gradlew", "build.gradle.kts", "build.gradle", "Makefile", "manage.py",
    })
end

-- shell command string for `scope` ("project" | "file"), or nil if none apply
function M.command_for(root, scope, main_class)
    if not root then return nil end
    local gradle = gradle_bin(root)
    if gradle then
        if scope == "file" and main_class and main_class ~= "" then
            return gradle .. " run -P" .. (cfg().run.main_property or "mainClass") .. "=" .. main_class
        end
        return gradle .. " run"
    end
    if exists(root .. "/Makefile") then return "make run" end
    if exists(root .. "/manage.py") then return "python3 manage.py runserver" end
    return nil
end

-- <package>.<Name> for a kotlin buffer (Name = file basename)
local function fqname(bufnr, suffix)
    local pkg
    for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        pkg = l:match("^%s*package%s+([%w_.]+)")
        if pkg then break end
    end
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t:r") .. (suffix or "")
    return pkg and (pkg .. "." .. name) or name
end

local function has_main(bufnr)
    for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        if l:match("^[%l ]*fun%s+main%s*%(") then return true end
    end
    return false
end

-- open `shell_cmd` in a fresh bottom split terminal at `cwd`; on_exit(code, buf).
-- What kotlinc reports on the way becomes diagnostics.
local function open_term(shell_cmd, cwd, on_exit)
    vim.cmd("botright " .. (cfg().run.height or 15) .. "new")
    local buf = vim.api.nvim_get_current_buf()
    local output = require("kotlin-lite.compiler").collector(cwd)
    vim.fn.jobstart({ vim.o.shell, vim.o.shellcmdflag, shell_cmd }, {
        term = true,
        cwd = cwd,
        on_stdout = output.on_stdout,
        on_exit = vim.schedule_wrap(function(_, code)
            output.done()
            if on_exit then on_exit(code, buf) end
        end),
    })
    vim.cmd("startinsert")
end

function M.run_project()
    local root = M.find_root()
    if not root then
        vim.notify("kotlin-lite: no project root found", vim.log.levels.WARN)
        return
    end
    local cmd = M.command_for(root, "project")
    if not cmd then
        vim.notify("kotlin-lite: no project runner found", vim.log.levels.WARN)
        return
    end
    open_term(cmd, root)
end

function M.run_file()
    local buf = vim.api.nvim_get_current_buf()
    local root = M.find_root(buf)
    if not root then
        vim.notify("kotlin-lite: no project root found", vim.log.levels.WARN)
        return
    end
    if not has_main(buf) then
        vim.notify("kotlin-lite: no top-level main() in this file", vim.log.levels.WARN)
        return
    end
    local cmd = M.command_for(root, "file", fqname(buf, "Kt"))
    if not cmd then
        vim.notify("kotlin-lite: no project runner found", vim.log.levels.WARN)
        return
    end
    open_term(cmd, root)
end

-------------------------------------------------------------------
-- tests
-------------------------------------------------------------------

-- directory of a gradle module (root when module is nil)
local function module_dir(root, module)
    if not module then return root end
    return root .. "/" .. module:gsub("^:", ""):gsub(":", "/")
end

-- gradle unit-test task for the module rooted at `dir`, given the test `file`
-- (optional). Inferred without querying gradle (which is slow):
--   * the file's source set -- src/commonTest, src/jvmTest -> jvmTest; src/test -> test
--   * else KMP by structure/build script (src/commonMain, or a *multiplatform*
--     plugin, matched case-insensitively) -> jvmTest
--   * else `test` (plain JVM, and Android whose `test` covers all variants)
-- Config `test.task` overrides everything.
function M.test_task(dir, file)
    if cfg().test.task then return cfg().test.task end

    local set = file and file:match("/src/([^/]+)/")
    if set == "test" then return "test" end
    if set and (set:match("^common") or set:match("^jvm")) then return "jvmTest" end

    if uv.fs_stat(dir .. "/src/commonMain") then return "jvmTest" end
    for _, f in ipairs({ "build.gradle.kts", "build.gradle" }) do
        local ok, lines = pcall(vim.fn.readfile, dir .. "/" .. f)
        if ok and table.concat(lines, "\n"):lower():find("multiplatform", 1, true) then
            return "jvmTest"
        end
    end
    return "test"
end

-- init script forcing per-test result logging + a total line (written once)
local function test_init_script()
    local path = vim.fn.stdpath("cache") .. "/kotlin-lite-test-init.gradle"
    pcall(vim.fn.writefile, {
        "allprojects {",
        "    tasks.withType(Test).configureEach {",
        "        testLogging {",
        '            events "passed", "skipped", "failed"',
        '            exceptionFormat "short"',
        "        }",
        "        afterSuite { desc, result ->",
        "            if (desc.parent == null) {",
        '                println "TEST RESULT: ${result.resultType} (${result.testCount} tests, "' ..
        '                    + "${result.successfulTestCount} passed, ${result.failedTestCount} failed, "' ..
        '                    + "${result.skippedTestCount} skipped)"',
        "            }",
        "        }",
        "    }",
        "}",
    }, path)
    return path
end

-- gradle sub-project paths from settings.gradle(.kts) include(...) lines
function M.modules(root)
    local seen, out = {}, {}
    for _, f in ipairs({ "settings.gradle.kts", "settings.gradle" }) do
        local ok, lines = pcall(vim.fn.readfile, root .. "/" .. f)
        if ok then
            for _, l in ipairs(lines) do
                if l:match("include") then
                    for m in l:gmatch("[\"']([:%w%-_.]+)[\"']") do
                        if m:sub(1, 1) == ":" and not seen[m] then
                            seen[m] = true
                            out[#out + 1] = m
                        end
                    end
                end
            end
        end
    end
    return out
end

-- gradle module path for `path` (":app", ":feature:login"), or nil for the root
-- project. Uses the conventional dir->path mapping (feature/login -> :feature:login).
function M.module_of(root, path)
    local moduleroot = vim.fs.root(path, { "build.gradle.kts", "build.gradle" })
    if not moduleroot or moduleroot == root then return nil end
    local rel = moduleroot:sub(#root + 2) -- strip "root/"
    return ":" .. rel:gsub("/", ":")
end

-- gradle command for a test run. `specs` are full task paths ({"test"},
-- {":app:test"}, {":app:test", ":core:data:jvmTest"}); tests = FQCN or nil.
function M.test_command(root, specs, tests)
    local gradle = gradle_bin(root)
    if not gradle then return nil end
    local parts = { gradle }
    vim.list_extend(parts, specs)
    parts[#parts + 1] = "--console=plain"
    parts[#parts + 1] = "--init-script " .. vim.fn.shellescape(test_init_script())
    if tests then parts[#parts + 1] = "--tests " .. vim.fn.shellescape(tests) end
    return table.concat(parts, " ")
end

local function xml_unescape(s)
    return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
        :gsub("&apos;", "'"):gsub("&#10;", " "):gsub("&amp;", "&"))
end

-- failed <testcase>s from JUnit XML under `root`, as quickfix items
function M.parse_failures(root, since)
    local xmls = vim.fn.glob(root .. "/**/build/test-results/**/*.xml", false, true)
    local items, resolved = {}, {}
    local function resolve(base)
        if resolved[base] == nil then
            local hit = vim.fs.find(base, { path = root, type = "file", limit = 1 })
            resolved[base] = hit[1] or false
        end
        return resolved[base]
    end

    for _, xml in ipairs(xmls) do
        local st = uv.fs_stat(xml)
        if st and (not since or st.mtime.sec >= since - 2) then
            local ok, lines = pcall(vim.fn.readfile, xml)
            if ok then
                -- drop self-closing (passing) <testcase .../> so they don't get
                -- swallowed into the next container testcase's block
                local content = table.concat(lines, "\n"):gsub("<testcase[^>]-/>", "")
                for block in content:gmatch("<testcase.-</testcase>") do
                    if block:find("<failure") or block:find("<error") then
                        local name = xml_unescape(block:match('name="([^"]*)"') or "?")
                        local cls = xml_unescape(block:match('classname="([^"]*)"') or "?")
                        local msg = block:match("<failure[^>]-message=\"([^\"]*)\"")
                            or block:match("<error[^>]-message=\"([^\"]*)\"") or "failed"
                        msg = xml_unescape(msg):gsub("%s+", " ")
                        local fbase, lnum = block:match("%(([%w_$]+%.%a+):(%d+)%)")
                        local file = fbase and resolve(fbase) or nil
                        local text = cls .. "." .. name .. "  " .. msg
                            .. (fbase and (" (" .. fbase .. ":" .. lnum .. ")") or "")
                        items[#items + 1] = file
                            and { filename = file, lnum = tonumber(lnum) or 1, text = text }
                            or { text = text, valid = 0 }
                    end
                end
            end
        end
    end
    return items
end

local function on_tests_done(code, buf, root, since)
    local summary
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
    if ok then
        for i = #lines, 1, -1 do
            local s = lines[i]:match("TEST RESULT:%s*(.+)")
            if s then summary = vim.trim(s); break end
        end
    end
    vim.notify(
        "kotlin-lite: tests " .. (code == 0 and "passed" or "FAILED")
        .. (summary and (" — " .. summary) or ""),
        code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
    )

    if cfg().test.quickfix ~= false then
        local items = M.parse_failures(root, since)
        if #items > 0 then
            vim.fn.setqflist({}, " ", { title = "Test failures", items = items })
            vim.cmd("botright copen 10")
        end
    end
end

-- Force a rerun (so per-test output + fresh XML always appear) by removing the
-- test task outputs, rather than relying on a clean<Task> that may not exist.
local function clean_outputs(dirs)
    if cfg().test.rerun == false then return end
    for _, d in ipairs(dirs) do
        vim.fn.delete(d .. "/build/test-results", "rf")
        vim.fn.delete(d .. "/build/reports/tests", "rf")
    end
end

local function run_tests(root, specs, dirs, tests)
    local cmd = M.test_command(root, specs, tests)
    if not cmd then
        vim.notify("kotlin-lite: no gradle project found", vim.log.levels.WARN)
        return
    end
    clean_outputs(dirs)
    local since = os.time()
    open_term(cmd, root, function(code, buf) on_tests_done(code, buf, root, since) end)
end

-- full task path for a module (":app:test") or root ("test")
local function spec_for(root, module, file)
    local dir = module_dir(root, module)
    return (module and (module .. ":") or "") .. M.test_task(dir, file), dir
end

function M.run_tests_file()
    local buf = vim.api.nvim_get_current_buf()
    local file = vim.api.nvim_buf_get_name(buf)
    local root = M.find_root(buf)
    if not root then
        vim.notify("kotlin-lite: no project root found", vim.log.levels.WARN)
        return
    end
    -- scope to the file's module so other modules don't fail with "no tests found"
    local module = M.module_of(root, file)
    local spec, dir = spec_for(root, module, file)
    run_tests(root, { spec }, { dir }, fqname(buf))
end

function M.run_tests_project()
    local root = M.find_root()
    if not root then
        vim.notify("kotlin-lite: no project root found", vim.log.levels.WARN)
        return
    end
    local mods = M.modules(root)
    if #mods > 1 then
        local items = { { text = "All modules", data = false } }
        for _, m in ipairs(mods) do items[#items + 1] = { text = m, data = m } end
        require("kotlin-lite.picker").select(items, { prompt = "Run tests in" }, function(mod)
            if mod == false then -- every module, each with its own task
                local specs, dirs = {}, {}
                for _, m in ipairs(mods) do
                    local s, d = spec_for(root, m)
                    specs[#specs + 1], dirs[#dirs + 1] = s, d
                end
                run_tests(root, specs, dirs, nil)
            else
                local spec, dir = spec_for(root, mod)
                run_tests(root, { spec }, { dir }, nil)
            end
        end)
    else
        local spec, dir = spec_for(root, nil)
        run_tests(root, { spec }, { dir }, nil)
    end
end

return M
