-- Incoming calls: the usages of a declaration, each with the function it is in.

local h = require("helpers")
local actions = require("kotlin-lite.actions")

local CALLS = "calls/Calls.kt"

local function callers(needle, word)
    h.open(CALLS)
    h.cursor_at(needle, word)
    actions.incoming_calls()
    h.wait(function() return #vim.fn.getqflist() > 0 end)
    return vim.tbl_map(function(it)
        return vim.fn.fnamemodify(vim.fn.bufname(it.bufnr), ":.") .. ":" .. it.lnum .. " " .. it.text
    end, vim.fn.getqflist())
end

describe("incoming calls", function()
    after_each(h.reset)

    local want = {
        "calls/Calls.kt:6 Counter.start: val start = tally(0)",
        "calls/Calls.kt:9 Counter.init: tally(1)",
        "calls/Calls.kt:14 Counter.bump: tally(it)",
        "calls/Calls.kt:19 Counter.twice: tally(tally(2))",
        "calls/Calls.kt:19 Counter.twice: tally(tally(2))",
        "calls/Calls.kt:22 Counter.Companion.zero: val zero = tally(-1)",
        "calls/Calls.kt:27 main: tally(4)",
        "calls/other/Ticker.kt:7 Ticker.tick: return tally(5)",
        "calls/other/Ticker.kt:15 TickerTest.`counts from seed`: check(tally(seed) == 2)",
    }

    it("from the declaration: every call, not the import", function()
        assert.are.same(want, callers("fun tally", "tally"))
    end)

    it("from a call", function()
        assert.are.same(want, callers("tally(4)", "tally"))
    end)

    it("titles the list", function()
        callers("fun tally", "tally")
        assert.are.equal("Callers: tally", vim.fn.getqflist({ title = true }).title)
    end)

    it("unresolved: a note", function()
        local note = h.capture_notify()
        h.open(CALLS)
        h.cursor_at("package calls", "calls")
        actions.incoming_calls()
        h.wait(function() return note.msg ~= nil end)
        assert.matches("^kotlin%-lite: ", note.msg)
    end)
end)
