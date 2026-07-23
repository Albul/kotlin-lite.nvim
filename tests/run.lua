-- Headless assertion runner for kotlin-lite.
--
--     nvim --headless -u tests/minimal_init.lua -l tests/run.lua
--
-- Drives the real actions against tests/fixtures/*.kt and checks that
-- gd (goto definition) and gr (find usages) behave as expected. Exits non-zero
-- if any check fails, so it can gate CI.

local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local fixtures = tests_dir .. "/fixtures"
vim.cmd.cd(fixtures) -- project root for rg = the fixtures dir

local actions = require("kotlin-lite.actions")

-------------------------------------------------------------------
-- tiny test harness
-------------------------------------------------------------------
local failures = 0

local function check(name, ok, detail)
    if ok then
        io.write(("  ok    %s\n"):format(name))
    else
        failures = failures + 1
        io.write(("  FAIL  %s%s\n"):format(name, detail and ("   ->   " .. detail) or ""))
    end
end

local function open(file)
    vim.cmd("edit! " .. vim.fn.fnameescape(fixtures .. "/" .. file))
    vim.bo.filetype = "kotlin"
end

--- 1-based line number of the first line containing literal `needle`.
local function line_of(needle)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        if l:find(needle, 1, true) then return i end
    end
end

--- Put the cursor on the first occurrence of `word` on line `lnum`.
local function cursor_on(lnum, word)
    local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
    local col = line:find(word, 1, true)
    vim.api.nvim_win_set_cursor(0, { lnum, col - 1 })
end

local function bufname()
    return vim.api.nvim_buf_get_name(0)
end

local function cur_line()
    return vim.api.nvim_win_get_cursor(0)[1]
end

-------------------------------------------------------------------
-- Test 1: gd -> declaration inside the same buffer (a local `val`)
-------------------------------------------------------------------
do
    open("Main.kt")
    local decl = line_of("val radius")
    local usage = line_of("Circle(radius)")
    cursor_on(usage, "radius")

    actions.goto_definition() -- in-buffer path is synchronous

    check("gd: local val -> same buffer", bufname():match("Main%.kt$") ~= nil and cur_line() == decl,
        ("expected line %s, got %s"):format(decl, cur_line()))
end

-------------------------------------------------------------------
-- Test 2: gd -> declaration in another file (class Circle)
-------------------------------------------------------------------
do
    open("Main.kt")
    local usage = line_of("Circle(radius)")
    cursor_on(usage, "Circle")

    actions.goto_definition() -- project path is async (rg + vim.schedule)
    local jumped = vim.wait(4000, function()
        return bufname():match("Geometry%.kt$") ~= nil
    end, 40)

    local on_class = jumped and (vim.api.nvim_get_current_line():find("class Circle", 1, true) ~= nil)
    check("gd: class -> Geometry.kt", on_class, "did not land on `class Circle`")
end

-------------------------------------------------------------------
-- Test 3: gr -> find usages populates the quickfix list
-------------------------------------------------------------------
do
    open("Main.kt")
    local usage = line_of("area(3.0")
    cursor_on(usage, "area")

    vim.fn.setqflist({}, "r") -- clear
    actions.find_usages()
    vim.wait(4000, function() return #vim.fn.getqflist() > 0 end, 40)

    local qf = vim.fn.getqflist()
    local files = {}
    for _, it in ipairs(qf) do
        files[vim.api.nvim_buf_get_name(it.bufnr):match("([^/]+)$")] = true
    end
    check("gr: usages of `area` == 4", #qf == 4, "got " .. #qf)
    check("gr: usages span Geometry.kt + Main.kt", files["Geometry.kt"] and files["Main.kt"] or false)
end

-------------------------------------------------------------------
-- Test 4: keymaps attach on a kotlin buffer
-------------------------------------------------------------------
do
    open("Main.kt")
    check("keymaps: attached to kotlin buffer", vim.b.kotlin_lite_attached == true)
    check("keymaps: gd is mapped (buffer-local)", vim.fn.maparg("gd", "n") ~= "")
end

-------------------------------------------------------------------
-- Test 5: alternate file toggle (main <-> test)
-------------------------------------------------------------------
do
    open("src/main/kotlin/com/example/Sample.kt")
    actions.alternate_file()
    check("alternate: main -> test", bufname():match("src/test/kotlin/com/example/SampleTest%.kt$") ~= nil,
        bufname())

    open("src/test/kotlin/com/example/SampleTest.kt")
    actions.alternate_file()
    check("alternate: test -> main", bufname():match("src/main/kotlin/com/example/Sample%.kt$") ~= nil,
        bufname())
end

-------------------------------------------------------------------
-- Test 6: copy fully-qualified name
-------------------------------------------------------------------
do
    open("Main.kt")
    check("copy_fqname: package + file name", actions.copy_fqname() == "fixtures.Main")
end

-------------------------------------------------------------------
-- Test 7: auto-import inserts an import for a class defined elsewhere
-------------------------------------------------------------------
do
    open("Main.kt")
    local usage = line_of("Circle(radius)")
    cursor_on(usage, "Circle")

    actions.auto_import_under_cursor()
    local added = vim.wait(4000, function()
        return line_of("import fixtures.Circle") ~= nil
    end, 40)
    check("auto_import: adds `import fixtures.Circle`", added)
end

-------------------------------------------------------------------
io.write("\n")
if failures == 0 then
    io.write("All checks passed.\n")
    vim.cmd("qall!")
else
    io.write(failures .. " check(s) failed.\n")
    vim.cmd(failures .. "cquit!")
end
