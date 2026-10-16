-- Types of declarations: grt, and gd through receivers whose type takes a
-- lookup (`a.b.c`, `f().x`, a local initialised from a chain).

local h = require("helpers")
local actions = require("kotlin-lite.actions")

local USE, MODEL = "grt/use/Use.kt", "grt/model/Model.kt"

-- run `action` on the `nth` `word` of the line with `needle`; waits for a
-- jump, a picker or a message -> captured picker, captured notify
local function run(action, needle, word, nth)
    local cap, note = h.capture_select(), h.capture_notify()
    h.open(USE)
    h.cursor_at(needle, word, nth)
    local buf, pos = h.bufname(), vim.api.nvim_win_get_cursor(0)
    action()
    h.wait(function()
        return cap.list ~= nil or note.msg ~= nil or h.bufname() ~= buf
            or not vim.deep_equal(vim.api.nvim_win_get_cursor(0), pos)
    end)
    return cap, note
end

local function assert_at(cap, file, needle, word)
    assert.is_nil(cap.list and h.format_rows(cap), "picker opened instead of a jump")
    assert.are.equal(file, h.relname())
    local lnum = h.line_of(needle)
    local col = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]:find(word, 1, true) - 1
    assert.are.same({ lnum, col }, vim.api.nvim_win_get_cursor(0))
end

describe("grt (type definition)", function()
    after_each(h.reset)

    local cases = {
        { "ctor param type", "// chain member", "car", "class Car", "Car" },
        { "member property type", "// chain member", "engine", "class Engine", "Engine" },
        { "fun return type", "// call result", "spare", "class Wheel", "Wheel" },
        { "local initialised from a chain", "// local typed by a chain", "e", "class Engine", "Engine" },
        { "top-level fun", "// top-level fun result", "garage", "class Car", "Car" },
        { "top-level val from a constructor", "// top-level val", "defaultCar", "class Car", "Car" },
        { "nullable type", "// nullable", "backup", "class Car", "Car" },
        { "expression-bodied fun", "// via owner()", "p", "data class Person", "Person" },
    }
    for _, c in ipairs(cases) do
        local name, needle, word, to_needle, to_word = unpack(c)
        it(name, function()
            assert_at(run(actions.goto_type_definition, needle, word), MODEL, to_needle, to_word)
        end)
    end

    it("on a class name: the class itself", function()
        local cap = run(actions.goto_type_definition, "class Driver", "Driver")
        assert.is_nil(cap.list)
        assert.are.equal(USE, h.relname())
        assert.are.equal(h.line_of("class Driver"), h.cur_line())
    end)

    it("a type without sources: says which", function()
        local _, note = run(actions.goto_type_definition, "println(n)", "n)")
        assert.truthy((note.msg or ""):find("Int", 1, true), note.msg)
    end)
end)

describe("gd through receivers that need a lookup", function()
    after_each(h.reset)

    local cases = {
        { "a.b.c: member of a member's type", "// chain member", "start", "fun start(): Boolean = true", "start" },
        { "local initialised from a chain", "// local typed by a chain", "power", "val power: Int = 1", "power" },
        { "f().x: member of the return type", "// call result", "pump", "    fun pump() {}", "pump" },
        { "top-level fun result", "// top-level fun result", "engine", "class Car(val engine", "engine" },
        { "top-level val", "// top-level val", "engine", "class Car(val engine", "engine" },
        { "nullable property", "// nullable", "spare", "fun spare(): Wheel = Wheel()", "spare" },
        { "local from an expression-bodied fun", "// via owner()", "name", "data class Person(val name", "name" },
        { "explicit import: not a same-named nested class of that package", "// explicit import", "Person",
            "data class Person(val name", "Person" },
    }
    for _, c in ipairs(cases) do
        local name, needle, word, to_needle, to_word = unpack(c)
        it(name, function()
            assert_at(run(actions.goto_definition, needle, word), MODEL, to_needle, to_word)
        end)
    end
end)
