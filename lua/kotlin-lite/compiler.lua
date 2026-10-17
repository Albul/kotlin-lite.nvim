-- Errors / warnings kotlinc prints during a run (gradle, make, ...) ->
-- vim.diagnostic, until the next run.

local M = {}

M.ns = vim.api.nvim_create_namespace("kotlin-lite-compiler")

local SEVERITY = {
    e = vim.diagnostic.severity.ERROR, error = vim.diagnostic.severity.ERROR,
    w = vim.diagnostic.severity.WARN, warning = vim.diagnostic.severity.WARN,
}

local function item(kind, path, lnum, col, message, cwd)
    if path:match("^file:") then
        path = vim.uri_to_fname(path)
    elseif cwd and not path:match("^/") then
        path = cwd .. "/" .. path
    end
    return {
        filename = path,
        lnum = tonumber(lnum),
        col = tonumber(col),
        severity = SEVERITY[kind],
        message = message,
    }
end

-- one line of output -> an item, else nil
local function parse_line(line, cwd)
    line = line:gsub("\27%[[%d;]*m", ""):gsub("\r", "")
    -- kotlinc 2: e: file:///path/Foo.kt:12:5 message
    local kind, path, lnum, col, msg = line:match("^([ew]): (file:%S-):(%d+):(%d+) (.*)$")
    if kind then return item(kind, path, lnum, col, msg) end
    -- kotlinc 1: e: /path/Foo.kt: (12, 5): message
    kind, path, lnum, col, msg = line:match("^([ew]): (.-): %((%d+), (%d+)%): (.*)$")
    if kind then return item(kind, path, lnum, col, msg) end
    -- kotlinc on the command line: path/Foo.kt:12:5: error: message
    path, lnum, col, kind, msg = line:match("^(%S.-%.kts?):(%d+):(%d+): (%a+): (.*)$")
    if SEVERITY[kind] then return item(kind, path, lnum, col, msg, cwd) end
end

--- `cwd`: where the run was, for relative paths
function M.parse(lines, cwd)
    local out = {}
    for _, line in ipairs(lines) do
        out[#out + 1] = parse_line(line, cwd)
    end
    return out
end

--- replace the diagnostics of the previous run with `items`
function M.publish(items)
    vim.diagnostic.reset(M.ns)
    local by_buf = {}
    for _, it in ipairs(items) do
        local buf = vim.fn.bufadd(it.filename)
        by_buf[buf] = by_buf[buf] or {}
        table.insert(by_buf[buf], {
            lnum = it.lnum - 1,
            col = it.col - 1,
            severity = it.severity,
            message = it.message,
            source = "kotlinc",
        })
    end
    for buf, diags in pairs(by_buf) do
        vim.diagnostic.set(M.ns, buf, diags)
    end
end

local function plural(n, word)
    return n .. " " .. word .. (n == 1 and "" or "s")
end

--- collects the output of a job run in `cwd`: on_stdout for jobstart,
--- done() publishes it
function M.collector(cwd)
    local lines, partial = {}, ""
    local C = {}
    function C.on_stdout(_, data)
        data[1] = partial .. data[1]
        partial = table.remove(data)
        vim.list_extend(lines, data)
    end
    function C.done()
        if partial ~= "" then lines[#lines + 1] = partial end
        local items = M.parse(lines, cwd)
        M.publish(items)
        local errors, warnings = 0, 0
        for _, it in ipairs(items) do
            if it.severity == vim.diagnostic.severity.ERROR then errors = errors + 1 else warnings = warnings + 1 end
        end
        if #items > 0 then
            vim.notify(("kotlin-lite: %s, %s"):format(plural(errors, "compiler error"), plural(warnings, "warning")),
                errors > 0 and vim.log.levels.ERROR or vim.log.levels.WARN)
        end
    end
    return C
end

return M
