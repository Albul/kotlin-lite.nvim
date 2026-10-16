local h = require("helpers")
local actions = require("kotlin-lite.actions")

-- name -> { kind, vis, count } over the outline of a fixture
local function outline(file)
    h.open(file)
    local by = {}
    for _, it in ipairs(actions._scan_symbols(vim.api.nvim_buf_get_lines(0, 0, -1, false))) do
        local e = by[it.name] or { count = 0 }
        e.kind, e.vis, e.count = it.kind, it.vis, e.count + 1
        by[it.name] = e
    end
    return by
end

describe("file structure outline", function()
    after_each(h.reset)

    describe("Structure.kt", function()
        local s
        before_each(function() s = outline("Structure.kt") end)

        it("shows the whole hierarchy regardless of visibility", function()
            for _, n in ipairs({ "TOP_CONST", "topVar", "topLevel", "hiddenFun", "Shape", "perimeter",
                "Point", "x", "secret", "visible", "hiddenField", "mutable", "distance", "ORIGIN" }) do
                assert.is_not_nil(s[n], n)
            end
        end)

        it("hides function locals and non-property params", function()
            for _, n in ipairs({ "localOnly", "tmp", "z" }) do
                assert.is_nil(s[n], n)
            end
        end)

        it("records kinds", function()
            assert.are.equal("class", s.Point.kind)
            assert.are.equal("fun", s.perimeter.kind)
            assert.are.equal("field", s.x.kind) -- ctor property
        end)

        it("records visibility for the fade sigil", function()
            assert.are.equal("private", s.secret.vis)
            assert.are.equal("private", s.hiddenField.vis)
            assert.are.equal("private", s.hiddenFun.vis)
            assert.are.equal("public", s.visible.vis)
        end)
    end)

    describe("StructureTricky.kt (braces in comments / strings)", function()
        it("nests by real braces only", function()
            local items = {}
            h.open("StructureTricky.kt")
            for _, it in ipairs(actions._scan_symbols(vim.api.nvim_buf_get_lines(0, 0, -1, false))) do
                items[#items + 1] = it.name .. "@" .. it.depth
            end
            assert.are.same({ "Tricky@0", "raw@1", "esc@1", "inside@1", "after@0" }, items)
        end)
    end)

    describe("Cycle.kt (multi-line ctor + secondary ctors)", function()
        local s
        before_each(function() s = outline("Cycle.kt") end)

        it("lists every primary-ctor property exactly once", function()
            for _, n in ipairs({ "type", "inhaleUnit", "retainUnit", "exhaleUnit",
                "sustainUnit", "reposeUnit", "millisPerUnit" }) do
                assert.is_not_nil(s[n], n)
            end
            assert.are.equal(1, s.inhaleUnit.count)
        end)

        it("shows public members of the class body", function()
            for _, n in ipairs({ "isReposeCycle", "cycleMillis", "isConstantCycle", "isConstantPhase",
                "getPhaseMillis" }) do
                assert.is_not_nil(s[n], n)
            end
            assert.are.equal("fun", s.getPhaseMillis.kind)
        end)

        it("shows private members", function()
            assert.are.equal("fun", s.convertToActualUnits.kind)
            assert.are.equal("fun", s.unitToMillis.kind)
        end)

        it("shows top-level const and companion members", function()
            assert.are.equal("field", s.PHASE_MILLIS_FACTOR.kind)
            assert.is_not_nil(s.asConstantPhase)
        end)
    end)
end)

describe("project symbols", function()
    local kind

    before_each(function()
        local cap = h.capture_select()
        h.open("Main.kt") -- cwd is the fixtures dir -> rg scans all fixtures
        actions.project_symbols()
        h.wait(function() return cap.list ~= nil end)
        kind = {}
        for _, s in ipairs(cap.list or {}) do kind[s.data.name] = s.data.kind end
    end)
    after_each(h.reset)

    it("includes top-level declarations", function()
        for _, n in ipairs({ "Circle", "Shape", "Point", "CyclePhase", "CycleType",
            "CycleEntry", "topLevel", "main", "describe" }) do
            assert.is_not_nil(kind[n], n)
        end
    end)

    it("records kinds (enum -> class, object -> object)", function()
        assert.are.equal("class", kind.CyclePhase)
        assert.are.equal("object", kind.CycleType)
    end)

    it("excludes nested members and fields", function()
        for _, n in ipairs({ "perimeter", "distance", "isReposeCycle", "asConstantPhase",
            "TOP_CONST", "inhaleUnit" }) do
            assert.is_nil(kind[n], n)
        end
    end)
end)
