-- Unused imports (hint diagnostics) and Organize Imports.

local h = require("helpers")
local organize = require("kotlin-lite.organize")

local function lines()
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

-- the unused imports, as their lines' text
local function unused()
    return vim.tbl_map(function(i) return i.text end, organize.unused(lines()))
end

describe("unused imports", function()
    before_each(function() h.open("organize/Unused.kt") end)
    after_each(h.reset)

    it("an import whose name the code never mentions", function()
        local u = unused()
        assert.is_true(vim.tbl_contains(u, "import java.io.File"))
        assert.is_true(vim.tbl_contains(u, "import a.b.Unused"))
    end)

    it("by its alias, not its name", function()
        local u = unused()
        assert.is_true(vim.tbl_contains(u, "import a.b.notUsed as alias"))
        assert.is_false(vim.tbl_contains(u, "import a.b.used as renamed"))
    end)

    it("a mention in a string or a comment doesn't count", function()
        local u = unused()
        assert.is_true(vim.tbl_contains(u, "import a.b.InString"))
        assert.is_true(vim.tbl_contains(u, "import a.b.InComment"))
    end)

    it("the second copy of an import", function()
        local u = unused()
        local flows = vim.tbl_filter(function(t) return t == "import kotlinx.coroutines.flow.Flow" end, u)
        assert.are.equal(1, #flows)
        assert.are.equal(18, organize.unused(lines())[#u].lnum)
    end)

    it("used ones: nested names, templates, KDoc links, extension calls", function()
        local u = unused()
        for _, used in ipairs({ "import a.b.Outer.Inner", "import a.b.InTemplate", "import a.b.Documented",
            "import a.b.second", "import kotlin.math.max" }) do
            assert.is_false(vim.tbl_contains(u, used), used)
        end
    end)

    it("never flagged: star imports and operator conventions", function()
        local u = unused()
        for _, kept in ipairs({ "import a.b.*", "import a.b.getValue", "import a.b.plus", "import a.b.component1" }) do
            assert.is_false(vim.tbl_contains(u, kept), kept)
        end
    end)

    it("exactly those", function()
        assert.are.same({
            "import java.io.File",
            "import a.b.notUsed as alias",
            "import a.b.Unused",
            "import a.b.InString",
            "import a.b.InComment",
            "import kotlinx.coroutines.flow.Flow",
        }, unused())
    end)
end)

describe("unused import diagnostics", function()
    after_each(h.reset)

    local function diags()
        return vim.diagnostic.get(0, { namespace = organize.ns })
    end

    it("hints, marked unnecessary, on the import lines", function()
        h.open("organize/Unused.kt")
        organize.refresh(0)
        local d = diags()
        assert.are.equal(6, #d)
        assert.are.equal(3, d[1].lnum)
        assert.are.equal(vim.diagnostic.severity.HINT, d[1].severity)
        assert.are.equal("Unused import java.io.File", d[1].message)
        assert.is_true(d[1]._tags.unnecessary)
    end)

    it("follow edits", function()
        h.open("organize/Unused.kt")
        organize.refresh(0)
        vim.api.nvim_buf_set_lines(0, -2, -2, false, { "    val f: File? = null" })
        organize.refresh(0)
        assert.are.equal(5, #diags())
    end)

    it("none in a clean file", function()
        h.open("organize/Clean.kt")
        organize.refresh(0)
        assert.are.same({}, diags())
    end)

    it("set when a kotlin buffer is attached", function()
        h.open("organize/Unused.kt")
        h.wait(function() return #diags() > 0 end, 1000)
        assert.are.equal(6, #diags())
    end)
end)

describe("organize imports", function()
    after_each(h.reset)

    it("drops the unused, sorts the rest the way ktlint does", function()
        h.open("organize/Unused.kt")
        organize.organize()
        assert.are.same({
            "package organize",
            "",
            "import a.b.*",
            "import a.b.Documented",
            "import a.b.InTemplate",
            "import a.b.Outer.Inner",
            "import a.b.component1",
            "import a.b.getValue",
            "import a.b.plus",
            "import a.b.second",
            "import kotlinx.coroutines.flow.Flow",
            "import kotlin.math.max",
            "import a.b.used as renamed",
            "",
            "/**",
        }, vim.list_slice(lines(), 1, 15))
    end)

    it("groups: others, java, javax, kotlin, then aliases", function()
        h.open("organize/Clean.kt")
        vim.api.nvim_buf_set_lines(0, 2, 3, false, {
            "import kotlin.math.max",
            "import javax.inject.Inject",
            "import a.b.x as y",
            "import java.io.File",
            "import kotlinx.coroutines.Job",
            "import A.B.Up",
        })
        vim.api.nvim_buf_set_lines(0, -1, -1, false, { "val all = listOf(max, Inject, y, File, Job, Up)" })
        organize.organize()
        assert.are.same({
            "import A.B.Up",
            "import kotlinx.coroutines.Job",
            "import java.io.File",
            "import javax.inject.Inject",
            "import kotlin.math.max",
            "import a.b.x as y",
        }, vim.list_slice(lines(), 3, 8))
    end)

    it("removing every import leaves one blank line after the package", function()
        h.open("organize/Clean.kt")
        vim.api.nvim_buf_set_lines(0, 4, 5, false, { "fun clean() = 1" })
        organize.organize()
        assert.are.same({ "package organize", "", "fun clean() = 1" }, lines())
    end)

    it("a clean, sorted file stays untouched", function()
        h.open("organize/Clean.kt")
        local tick = vim.api.nvim_buf_get_changedtick(0)
        organize.organize()
        assert.are.equal(tick, vim.api.nvim_buf_get_changedtick(0))
    end)

    it("comments among the imports: only the unused go, the order stays", function()
        h.open("organize/Clean.kt")
        vim.api.nvim_buf_set_lines(0, 2, 3, false, {
            "import z.Z",
            "// keep",
            "import a.b.Used",
            "import a.b.Gone",
        })
        vim.api.nvim_buf_set_lines(0, -1, -1, false, { "val z = Z" })
        organize.organize()
        assert.are.same({ "import z.Z", "// keep", "import a.b.Used", "" }, vim.list_slice(lines(), 3, 6))
    end)

    it("is mapped to <leader>co", function()
        h.open("organize/Clean.kt")
        assert.are.equal("Organize imports (kotlin-lite)", vim.fn.maparg("<leader>co", "n", false, true).desc)
    end)
end)
