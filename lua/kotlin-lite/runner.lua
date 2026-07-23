-- Run the file / project in a bottom terminal split.
--
-- Gradle-first (wrapper preferred), with make / manage.py fallbacks. Running a
-- specific file's main is passed as a gradle property (see config.run) that the
-- application build can wire to `mainClass`; without that wiring it runs the
-- project's configured main.

local M = {}

local uv = vim.uv or vim.loop

local function cfg()
    return require("kotlin-lite.config").options
end

local function exists(p)
    return p ~= nil and uv.fs_stat(p) ~= nil
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

    local gradle
    if exists(root .. "/gradlew") then
        gradle = "./gradlew"
    elseif exists(root .. "/build.gradle.kts") or exists(root .. "/build.gradle") then
        gradle = "gradle"
    end
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

-- FQ main class for a kotlin buffer: <package>.<File>Kt
local function main_class(bufnr)
    local pkg
    for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        pkg = l:match("^%s*package%s+([%w_.]+)")
        if pkg then break end
    end
    local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t:r")
    local cls = file .. "Kt"
    return pkg and (pkg .. "." .. cls) or cls
end

local function has_main(bufnr)
    for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        if l:match("^[%l ]*fun%s+main%s*%(") then return true end
    end
    return false
end

-- open `shell_cmd` in a fresh bottom split terminal running at `cwd`
local function open_term(shell_cmd, cwd)
    vim.cmd("botright " .. (cfg().run.height or 15) .. "new")
    vim.fn.jobstart({ vim.o.shell, vim.o.shellcmdflag, shell_cmd }, { term = true, cwd = cwd })
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
    local cmd = M.command_for(root, "file", main_class(buf))
    if not cmd then
        vim.notify("kotlin-lite: no project runner found", vim.log.levels.WARN)
        return
    end
    open_term(cmd, root)
end

return M
