-- resolve.lua: item.sym, and resolution in a file without a buffer.

local h = require("helpers")
local resolve = require("kotlin-lite.resolve")
local scope = require("kotlin-lite.scope")

local function at(file, needle, word, nth)
    h.open(file)
    h.cursor_at(needle, word, nth)
    local res
    resolve.at_cursor(function(r) res = r end)
    h.wait(function() return res ~= nil end)
    assert.is_not_nil(res, "no result")
    return res
end

local function owner_names(sym)
    return table.concat(vim.tbl_map(function(o) return o.name end, sym.owners), ".")
end

describe("resolve: symbol of the result", function()
    after_each(h.reset)

    local dsl, use = "gd/dsl/Dsl.kt", "gd/dsl/UseDsl.kt"

    it("member fun from another file: kind, owner, package", function()
        local res = at(use, "// apply on pen", "stroke")
        local s = res.jump.sym
        assert.are.equal("fun", s.kind)
        assert.are.equal("stroke", s.name)
        assert.are.equal("Pen", owner_names(s))
        assert.are.equal("gd.dsl", s.pkg)
        assert.are.equal("public", s.vis)
        assert.is_nil(s.range)
    end)

    it("top-level fun: no owners", function()
        local s = at(use, "// dsl canvas", "canvas").jump.sym
        assert.are.equal("fun", s.kind)
        assert.are.equal("", owner_names(s))
        assert.are.equal("gd.dsl", s.pkg)
    end)

    it("member declared in this buffer (cursor on it)", function()
        local res = at(dsl, "fun stroke(width: Int, dash", "stroke")
        assert.is_true(res.here)
        local s = res.jump.sym
        assert.are.equal("fun", s.kind)
        assert.are.equal("Pen", owner_names(s))
        assert.are.equal("gd.dsl", s.pkg)
    end)

    it("type declared in this buffer", function()
        local s = at(dsl, "class Pen", "Pen").jump.sym
        assert.are.equal("type", s.kind)
        assert.are.equal("", owner_names(s))
    end)

    it("local val: kind local, its scope range", function()
        local res = at(use, "p.apply", "p")
        local s = res.jump.sym
        assert.are.equal("local", s.kind)
        assert.is_not_nil(s.range)
        local from_l = scope.unkey(s.range.from)
        assert.are.equal(h.line_of("val p = Pen()"), from_l)
    end)

    it("parameter", function()
        local s = at("gd/scope/Scoped.kt", "println(local * 2)", "local").jump.sym
        assert.are.equal("param", s.kind)
        assert.is_not_nil(s.range)
    end)

    it("named argument -> param of the callee", function()
        local s = at(use, "pen(tint", "tint").jump.sym
        assert.are.equal("param", s.kind)
    end)

    it("expect member: mp inherited from the expect class", function()
        local s = at("defs/shared/src/commonMain/kotlin/KmpClock.kt", "fun now", "now").jump.sym
        assert.are.equal("expect", s.mp)
        assert.are.equal("KmpClock", owner_names(s))
        assert.are.equal("defs", s.pkg)
    end)

    it("visibility", function()
        local s = at("impl/painters/Painters.kt", "private fun hidden", "hidden").jump.sym
        assert.are.equal("private", s.vis)
    end)

    it("pool items carry symbols too", function()
        local res = at("defs/shared/src/commonMain/kotlin/UseClock.kt", "fun useClock", "KmpClock")
        assert.is_not_nil(res.pool)
        for _, it in ipairs(res.pool) do
            assert.are.equal("type", it.sym.kind)
        end
    end)
end)

describe("resolve: a file not open in a buffer", function()
    after_each(h.reset)

    it("context from path + lines resolves like gd", function()
        local path = h.fixtures .. "/gd/dsl/UseDsl.kt"
        assert.are.equal(-1, vim.fn.bufnr(path))
        local lines = vim.fn.readfile(path)
        local base = resolve.base_of(path, lines)
        local lnum
        for i, l in ipairs(lines) do
            if l:find("lazyPen.stroke", 1, true) then lnum = i break end
        end
        local ctx = resolve.context_at(base, lnum, lines[lnum]:find("stroke", 1, true) - 1)
        local res = resolve.run_sync(ctx)
        assert.is_not_nil(res.jump)
        assert.truthy(res.jump.filename:find("gd/dsl/Dsl.kt", 1, true))
        assert.are.equal(8, res.jump.lnum)
        assert.are.equal(-1, vim.fn.bufnr(path), "opened a buffer")
    end)

    it("locals in that file resolve from its own lines", function()
        local path = h.fixtures .. "/gd/scope/Scoped.kt"
        local lines = vim.fn.readfile(path)
        local base = resolve.base_of(path, lines)
        local lnum
        for i, l in ipairs(lines) do
            if l:find("println(local * 2)", 1, true) then lnum = i break end
        end
        local res = resolve.run_sync(resolve.context_at(base, lnum, lines[lnum]:find("local", 1, true) - 1))
        assert.is_true(res.here)
        assert.are.equal(path, res.jump.filename)
        assert.are.equal(16, res.jump.lnum)
    end)
end)
