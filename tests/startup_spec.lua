-- Startup cost: a fresh nvim (own HOME with a gradle cache, this plugin only)
-- must not scan the disk until a kotlin buffer / gradle project shows up.
local h = require("helpers")

local repo = vim.fn.fnamemodify(h.fixtures, ":h:h")

-- records the disk-scanning calls the plugin makes, installed before it loads
-- (upward vim.fs.find = vim.fs.root's few stats: cheap, not recorded)
local SPY = [[lua _G.calls = {}
    local function spy(t, k, name) local f = t[k]
        t[k] = function(...) local n = name(...); if n then table.insert(_G.calls, n) end; return f(...) end end
    spy(vim.fs, "find", function(a, o) if not (o and o.upward) then return "fs.find " .. tostring(a) end end)
    spy(vim.fs, "dir", function(a) return "fs.dir " .. tostring(a) end)
    spy(vim, "system", function(a) return "system " .. a[1] end)]]

-- run `lua` in a clean child nvim started in an empty, non-gradle HOME
-- -> the disk-scanning calls made
local function child(lua)
    local home = vim.fn.tempname()
    vim.fn.mkdir(home .. "/.gradle/caches/modules-2/files-2.1", "p")
    vim.fn.mkdir(home .. "/.cache/nvim/kotlin-lite-jars", "p")
    finally(function() vim.fn.delete(home, "rf") end)
    local script = ([[
        %s
        vim.wait(300, function() return false end)
        io.stdout:write(vim.json.encode(_G.calls))
        vim.cmd("qall!")
    ]]):format(lua)
    local res = vim.system({ "nvim", "--clean", "--headless",
        "--cmd", (SPY:gsub("\n", " ")), "--cmd", "set rtp^=" .. repo,
        "-c", "lua " .. script:gsub("\n", " ") }, {
        cwd = home,
        env = { HOME = home, XDG_CACHE_HOME = home .. "/.cache", XDG_CONFIG_HOME = home .. "/.config" },
        text = true,
    }):wait(10000)
    assert.are.equal(0, res.code, res.stderr)
    return vim.json.decode(res.stdout)
end

local function has(calls, prefix)
    for _, c in ipairs(calls) do
        if c:sub(1, #prefix) == prefix then return true end
    end
    return false
end

describe("startup", function()
    it("a plain startup scans nothing", function()
        assert.are.same({}, child(""))
    end)

    it("the first kotlin buffer scans the jar cache and the gradle caches", function()
        local calls = child([[
            vim.cmd("enew")
            vim.bo.filetype = "kotlin"
            require("kotlin-lite.jars").jar_dirs()
        ]])
        assert.is_true(has(calls, "fs.dir "), vim.inspect(calls))
        assert.is_true(has(calls, "system find"), vim.inspect(calls))
        assert.is_false(has(calls, "fs.find "), vim.inspect(calls)) -- no tree walk for Android
    end)
end)
