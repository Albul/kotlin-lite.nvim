local h = require("helpers")
local actions = require("kotlin-lite.actions")

describe("tag stack", function()
    after_each(h.reset)

    it("<C-t> (:pop) walks back gd by gd, skipping jumps in between", function()
        -- hop 1: Main.kt (Circle) -> Geometry.kt
        h.open("Main.kt")
        local l1 = h.line_of("Circle(radius)")
        h.cursor_on(l1, "Circle")
        local c1 = vim.api.nvim_win_get_cursor(0)[2]
        actions.goto_definition()
        assert.is_true(h.wait_jump())

        -- noise between hops: <C-o> would have to walk through these, <C-t> must not
        vim.cmd("normal! G")
        vim.cmd("normal! gg")

        -- hop 2: inside Geometry.kt, an in-buffer gd (radius -> `val radius`)
        local l2 = h.line_of("return PI * radius")
        h.cursor_on(l2, "radius")
        actions.goto_definition()

        local st = vim.fn.gettagstack()
        assert.are.equal(2, st.length)
        assert.are.equal(3, st.curidx)
        assert.are.same({ "Circle", "radius" }, { st.items[1].tagname, st.items[2].tagname })

        vim.cmd("pop")
        assert.are.equal("Geometry.kt", h.relname())
        assert.are.equal(l2, h.cur_line())

        vim.cmd("pop")
        assert.are.equal("Main.kt", h.relname())
        assert.are.same({ l1, c1 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("a cancelled picker pushes nothing", function()
        local asked = false
        h.stub(vim.ui, "select", function(_, _, cb) asked = true; cb(nil) end)
        h.open("defs/imports/user/Bare.kt")
        h.cursor_at("fun bare", "Dup")
        actions.goto_definition()
        h.wait(function() return asked end)
        assert.is_true(asked)
        assert.are.equal(0, vim.fn.gettagstack().length)
    end)
end)

describe("'tagfunc'", function()
    after_each(h.reset)

    local function file_of(t) return t and t.filename:match("([^/]+/[^/]+)$") end
    local function lnum_of(t) return t and tonumber(t.cmd:match("%%(%d+)l")) end

    it("is set on kotlin buffers", function()
        h.open("Main.kt")
        assert.matches("kotlin%-lite", vim.bo.tagfunc)
    end)

    it("falls back for insert-mode completion and regex", function()
        h.open("Main.kt")
        assert.are.equal(vim.NIL, actions.tagfunc("Cir", "i"))
        assert.are.equal(vim.NIL, actions.tagfunc("^Cir", "r"))
    end)

    it("class in another file, best first, cmd addresses line + column", function()
        h.open("Main.kt")
        h.cursor_at("Circle(radius)", "Circle")
        local tags = actions.tagfunc("Circle", "c")
        assert.matches("Geometry%.kt$", tags[1].filename)
        assert.are.equal("Circle", tags[1].name)
        assert.are.equal("/\\%8l\\%1c/", tags[1].cmd)
    end)

    it("local decl from the buffer", function()
        h.open("Main.kt")
        h.cursor_at("Circle(radius)", "radius")
        local tags = actions.tagfunc("radius", "c")
        assert.are.equal(1, #tags)
        assert.matches("Main%.kt$", tags[1].filename)
        assert.are.equal(h.line_of("val radius"), lnum_of(tags[1]))
    end)

    it("import line -> imported decl", function()
        h.open("defs/imports/user/User.kt")
        h.cursor_at("import defs.other.Dup", "other")
        local tags = actions.tagfunc("other", "c")
        assert.are.same({ "other/Dup.kt" }, vim.tbl_map(file_of, tags))
    end)

    it("header-ranked first", function()
        h.open("defs/imports/user/Mixed.kt")
        h.cursor_at("fun mixed", "Twin")
        local files = vim.tbl_map(file_of, actions.tagfunc("Twin", "c"))
        assert.are.equal(3, #files)
        assert.are.equal("extra/Twin.kt", files[1])
        assert.are.equal("other/Twin.kt", files[3])
    end)

    it(":tag Circle jumps by name", function()
        h.open("Main.kt")
        vim.cmd("tag Circle")
        assert.are.equal("Geometry.kt", h.relname())
        assert.are.equal(8, h.cur_line())
    end)

    it("<C-]> jumps and pushes the tag stack", function()
        h.open("Main.kt")
        h.cursor_at("Circle(radius)", "Circle")
        vim.cmd("execute \"normal! \\<C-]>\"")
        assert.are.equal("Geometry.kt", h.relname())
        assert.are.equal(8, h.cur_line())
        assert.is_true(vim.fn.gettagstack().length >= 1)
    end)

    it("<C-w>] opens the definition in a new split", function()
        h.open("Main.kt")
        h.cursor_at("Circle(radius)", "Circle")
        local wins = #vim.api.nvim_tabpage_list_wins(0)
        vim.cmd("execute \"normal! \\<C-w>]\"")
        assert.are.equal(wins + 1, #vim.api.nvim_tabpage_list_wins(0))
        assert.are.equal("Geometry.kt", h.relname())
        vim.cmd("close")
        assert.are.equal("Main.kt", h.relname())
    end)

    it(":ptag previews without moving the cursor", function()
        h.open("Main.kt")
        vim.cmd("ptag Circle")
        local preview
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.wo[w].previewwindow then preview = w end
        end
        assert.is_not_nil(preview)
        assert.matches("Geometry%.kt$", vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(preview)))
        assert.are.equal("Main.kt", h.relname())
    end)
end)
