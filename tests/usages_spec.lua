local h = require("helpers")
local actions = require("kotlin-lite.actions")
local search = require("kotlin-lite.search")

describe("gu / gr (find usages)", function()
    after_each(h.reset)

    local function usages(file, needle, word)
        h.open(file)
        h.cursor_at(needle, word)
        actions.find_usages()
        h.wait(function() return #vim.fn.getqflist() > 0 end)
        return vim.fn.getqflist()
    end

    it("fills the quickfix list across files (the top-level fun, not the member)", function()
        local qf = usages("Main.kt", "area(3.0", "area")
        local got = {}
        for _, it in ipairs(qf) do
            got[#got + 1] = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(it.bufnr), ":t") .. ":" .. it.lnum
        end
        table.sort(got)
        assert.are.same({ "Geometry.kt:17", "Main.kt:8" }, got)
    end)

    it("skips comment / KDoc mentions", function()
        local qf = usages("Geometry.kt", "class Circle", "radius")
        assert.is_true(#qf > 0)
        for _, it in ipairs(qf) do
            assert.falsy(it.text:find("[radius]", 1, true))
        end
    end)
end)

describe("search.is_comment_text", function()
    it("detects KDoc and block comments", function()
        assert.is_true(search.is_comment_text("  * [radius]"))
        assert.is_true(search.is_comment_text("/* x */"))
    end)

    it("ignores code with a trailing comment", function()
        assert.is_false(search.is_comment_text("val a = b // c"))
    end)
end)

describe("gu by what the name resolves to", function()
    after_each(h.reset)

    local ACC, BANK = "usages/a/Account.kt", "usages/b/Bank.kt"

    -- gu on the `nth` `word` of the line with `needle` -> sorted "dir/File.kt:line"
    local function gu(file, needle, word, nth)
        vim.fn.setqflist({}, "r")
        h.open(file)
        h.cursor_at(needle, word, nth)
        actions.find_usages()
        h.wait(function() return #vim.fn.getqflist() > 0 end)
        local out = {}
        for _, it in ipairs(vim.fn.getqflist()) do
            local name = vim.api.nvim_buf_get_name(it.bufnr):match("([^/]+/[^/]+)$")
            out[#out + 1] = name .. ":" .. it.lnum
        end
        table.sort(out)
        return table.concat(out, " ")
    end

    local cases = {
        { "member: not a shadowing local, a same-named member elsewhere, a typed receiver of another class",
            ACC, "var balance = 0", "balance", 1, "a/Account.kt:15 a/Account.kt:4 a/Account.kt:8 b/Bank.kt:12 b/Bank.kt:13 b/Bank.kt:14 b/Bank.kt:7" },
        { "from a usage in another file", BANK, "a.balance = 1", "balance", 1,
            "a/Account.kt:15 a/Account.kt:4 a/Account.kt:8 b/Bank.kt:12 b/Bank.kt:13 b/Bank.kt:14 b/Bank.kt:7" },
        { "local: its scope only", ACC, "val balance = 5", "balance", 1, "a/Account.kt:10 a/Account.kt:9" },
        { "private member: its file", ACC, "private val secret", "secret", 1,
            "a/Account.kt:11 a/Account.kt:15 a/Account.kt:5" },
        { "top-level fun: files that see it (import line included)", BANK, "open(name", "open", 1,
            "a/Account.kt:23 b/Bank.kt:10 b/Bank.kt:12 b/Bank.kt:4" },
        { "fun param: its body and named arguments at calls", ACC, "fun deposit(amount", "amount", 1,
            "a/Account.kt:7 a/Account.kt:8 b/Bank.kt:10" },
    }
    for _, c in ipairs(cases) do
        local name, file, needle, word, nth, want = unpack(c)
        it(name, function()
            assert.are.equal(want, gu(file, needle, word, nth))
        end)
    end

    it("columns point at each occurrence", function()
        gu(ACC, "var balance = 0", "balance")
        for _, it in ipairs(vim.fn.getqflist()) do
            local line = vim.fn.readfile(vim.api.nvim_buf_get_name(it.bufnr))[it.lnum]
            assert.are.equal("balance", line:sub(it.col, it.col + #"balance" - 1))
        end
    end)
end)

describe("rename by what the name resolves to", function()
    local ACC, BANK = "usages/a/Account.kt", "usages/b/Bank.kt"
    local saved = {}

    before_each(function()
        for _, f in ipairs({ ACC, BANK }) do saved[f] = vim.fn.readfile(h.fixtures .. "/" .. f) end
    end)
    after_each(function()
        h.reset()
        for f, lines in pairs(saved) do vim.fn.writefile(lines, h.fixtures .. "/" .. f) end
    end)

    local preview = h.rename_preview
    local function press(lhs, needle) h.preview_press(lhs, needle) end
    -- the preview's lines once its guesses are looked into
    local function rows()
        local function get() return vim.api.nvim_buf_get_lines(preview(), 0, -1, false) end
        h.wait(function() return not table.concat(get(), "\n"):find("checking the receivers", 1, true) end)
        vim.wait(80) -- the last render
        return get()
    end

    -- rename `word` -> `new`; `keys`: what to press in the preview (default <CR>)
    local function rename(file, needle, word, new, keys)
        h.stub(vim.ui, "input", function(_, cb) cb(new) end)
        h.open(file)
        h.cursor_at(needle, word)
        local tick = vim.b.changedtick
        actions.rename()
        if keys ~= false then
            if preview() then
                rows()
                for _, k in ipairs(keys or { { "<CR>" } }) do press(k[1], k[2]) end
            end
        end
        h.wait(function() return vim.b.changedtick ~= tick end, keys == false and 1 or nil)
    end

    local function lines(file)
        local b = vim.fn.bufnr(h.fixtures .. "/" .. file)
        if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
        return vim.fn.readfile(h.fixtures .. "/" .. file)
    end

    it("a local: only its scope, in the buffer, not written", function()
        rename(ACC, "val balance = 5", "balance", "bal")
        local l = lines(ACC)
        assert.are.equal("        val bal = 5 // shadows the member", l[9])
        assert.are.equal("        println(bal)", l[10])
        assert.are.equal("        balance += amount", l[8])
        assert.are.equal("    var balance = 0", l[4])
        assert.is_true(vim.bo.modified)
        assert.are.same(saved[ACC], vim.fn.readfile(h.fixtures .. "/" .. ACC))
    end)

    it("a member: its usages across files, nothing else, saved", function()
        rename(ACC, "var balance = 0", "balance", "funds")
        h.wait(function() return vim.fn.readfile(h.fixtures .. "/" .. BANK)[7]:find("funds") ~= nil end)
        local a, b = vim.fn.readfile(h.fixtures .. "/" .. ACC), vim.fn.readfile(h.fixtures .. "/" .. BANK)
        assert.are.equal("    var funds = 0", a[4])
        assert.are.equal("        funds += amount", a[8])
        assert.are.equal("        val balance = 5 // shadows the member", a[9])
        assert.are.equal("        println(balance)", a[10])
        assert.are.equal("    // balance in a comment", a[14])
        assert.are.equal("    fun total(): Int = funds + secret", a[15])
        assert.are.equal("    var balance = 100", a[19])
        assert.are.equal("    a.funds = 1", b[7])
        assert.are.equal("    l.balance = 2", b[9])
        assert.are.equal('    println("balance")', b[11])
        assert.are.equal('    open(name = "y").funds = 4', b[12], "the receiver's type looked up: Account")
        assert.are.equal("    ledger().balance = 5", b[13], "the receiver's type looked up: Ledger")
        assert.are.equal("    unknownThing().balance = 6", b[14], "a guess: unchecked")
    end)

    it("the preview: by file, certain ones checked, guesses not", function()
        rename(ACC, "var balance = 0", "balance", "funds", false)
        local r = rows()
        assert.are.equal("Rename balance → funds   5 of 7 selected", r[1])
        local function row(needle)
            for _, l in ipairs(r) do
                if l:find(needle, 1, true) then return l end
            end
        end
        local all = table.concat(r, "\n")
        assert.is_not_nil(row("[x]      4  var balance = 0"), all)
        assert.is_not_nil(row("[x]      7  a.balance = 1"), all)
        assert.is_not_nil(row('[x]     12  open(name = "y").balance = 4'), all)
        assert.is_not_nil(row("[ ]?    14  unknownThing().balance = 6"), all)
        assert.is_not_nil(row("[ ]     13  ledger().balance = 5"), all)
        -- the new name shown inline at each checked occurrence
        local ns = require("kotlin-lite.rename_preview").ns
        local inline = 0
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(preview(), ns, 0, -1, { details = true })) do
            local vt = m[4].virt_text
            if vt and vt[1][1] == "funds" then
                inline = inline + 1
                assert.are.equal("balance", r[m[2] + 1]:sub(m[3] + 1, m[4].end_col))
            end
        end
        assert.are.equal(5, inline)
        -- the other type said
        local said
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(preview(), ns, 0, -1, { details = true })) do
            local vt = m[4].virt_text
            if vt and vt[1][1] == "  ← Ledger" then said = r[m[2] + 1] end
        end
        assert.are.equal("  [ ]     13  ledger().balance = 5", said)
        press("q")
        assert.is_nil(preview(true))
        assert.are.same(saved[ACC], vim.fn.readfile(h.fixtures .. "/" .. ACC))
    end)

    it("a guess checked by hand is renamed too", function()
        rename(ACC, "var balance = 0", "balance", "funds", { { "<Space>", "unknownThing" }, { "<CR>" } })
        h.wait(function() return vim.fn.readfile(h.fixtures .. "/" .. BANK)[14]:find("funds") ~= nil end)
        assert.are.equal("    unknownThing().funds = 6", vim.fn.readfile(h.fixtures .. "/" .. BANK)[14])
        assert.are.equal("    a.funds = 1", vim.fn.readfile(h.fixtures .. "/" .. BANK)[7])
    end)

    it("a file unchecked as a whole stays as it is", function()
        rename(ACC, "var balance = 0", "balance", "funds", { { "<Space>", "Bank" }, { "<CR>" } })
        h.wait(function() return vim.fn.readfile(h.fixtures .. "/" .. ACC)[4]:find("funds") ~= nil end)
        assert.are.equal("    var funds = 0", vim.fn.readfile(h.fixtures .. "/" .. ACC)[4])
        assert.are.same(saved[BANK], vim.fn.readfile(h.fixtures .. "/" .. BANK))
    end)

    it("an occurrence changed after the preview opened: skipped, said", function()
        local cap = h.capture_notify()
        rename(ACC, "var balance = 0", "balance", "funds", false)
        assert.is_not_nil(preview())
        local b = vim.fn.bufadd(h.fixtures .. "/" .. BANK)
        vim.fn.bufload(b)
        vim.api.nvim_buf_set_lines(b, 6, 7, false, { "    a.other = 1" })
        vim.api.nvim_buf_call(b, function() vim.cmd("silent update") end)
        press("<CR>")
        h.wait(function() return cap.msg ~= nil end)
        assert.is_truthy(cap.msg:find("1 skipped (changed since the preview)", 1, true), cap.msg)
        assert.are.equal("    a.other = 1", vim.fn.readfile(h.fixtures .. "/" .. BANK)[7])
        assert.are.equal("    var funds = 0", vim.fn.readfile(h.fixtures .. "/" .. ACC)[4])
    end)

    it("unresolved: every mention previewed, said so", function()
        rename(BANK, 'println("balance")', "println", "say", false)
        local r = rows()
        assert.is_truthy(r[3]:find("every mention of 'println'", 1, true), r[3])
        press("q")
        assert.are.same(saved[BANK], vim.fn.readfile(h.fixtures .. "/" .. BANK))
    end)

    it("a file with unsaved changes: edited, not written", function()
        local cap = h.capture_notify()
        vim.cmd("edit! " .. vim.fn.fnameescape(h.fixtures .. "/" .. BANK))
        vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// mine" })
        rename(ACC, "var balance = 0", "balance", "funds")
        h.wait(function() return vim.fn.readfile(h.fixtures .. "/" .. ACC)[4]:find("funds") ~= nil end)
        assert.are.same(saved[BANK], vim.fn.readfile(h.fixtures .. "/" .. BANK))
        local b = vim.api.nvim_buf_get_lines(vim.fn.bufnr(h.fixtures .. "/" .. BANK), 0, -1, false)
        assert.are.equal("// mine", b[1])
        assert.are.equal("    a.funds = 1", b[8])
        assert.is_true(vim.bo[vim.fn.bufnr(h.fixtures .. "/" .. BANK)].modified)
        assert.is_truthy(cap.msg:find("not written (had unsaved changes): ", 1, true), cap.msg)
        assert.is_truthy(cap.msg:find("Bank.kt", 1, true), cap.msg)
    end)
end)

describe("rename preview controller", function()
    after_each(h.reset)

    it("a verdict checks / unchecks a guess, not one the user toggled", function()
        local path = h.fixtures .. "/usages/a/Account.kt"
        local items = {
            { filename = path, lnum = 4, col = 9, end_col = 16, guess = true },
            { filename = path, lnum = 8, col = 9, end_col = 16, guess = true },
            { filename = path, lnum = 15, col = 24, end_col = 31, guess = true },
        }
        local ctrl = require("kotlin-lite.rename_preview").open(items, { word = "balance", new = "funds", on_apply = function() end })
        h.preview_press("<Space>", "balance += amount") -- the user checks line 8
        ctrl.update(items[1], "sure")
        ctrl.update(items[2], false, "Ledger")
        ctrl.update(items[3], false, "Ledger")
        vim.wait(80)
        local r = vim.api.nvim_buf_get_lines(ctrl.buf, 0, -1, false)
        local all = table.concat(r, "\n")
        assert.is_truthy(all:find("[x]      4  var balance", 1, true), all)
        assert.is_truthy(all:find("[x]      8  balance += amount", 1, true), all)
        assert.is_truthy(all:find("[ ]     15  fun total", 1, true), all)
        assert.is_falsy(all:find("[?]", 1, true), all)
    end)
end)
