-- File reads for one request: each file read once, only as deep as needed.

local imports = require("kotlin-lite.imports")

local M = {}

local HEAD = 40

function M.new()
    local files, pkgs, heads, need = {}, {}, {}, {}
    -- need[path]: deepest line some hit needs, so one read covers them all
    local R = { need = need }

    --- first `upto` lines (at least need[path]); all when `upto` is nil
    function R.lines(path, upto)
        if upto then upto = math.max(upto, need[path] or 0, HEAD) end
        local f = files[path]
        if f and (f.all or (upto and f.n >= upto)) then return f.lines end
        local ok, lines
        if upto then
            ok, lines = pcall(vim.fn.readfile, path, "", upto)
        else
            ok, lines = pcall(vim.fn.readfile, path)
        end
        lines = ok and lines or {}
        files[path] = { lines = lines, n = upto or #lines, all = not upto or #lines < upto }
        return lines
    end

    function R.has(path)
        return files[path] ~= nil
    end

    function R.package(path)
        if pkgs[path] == nil then
            pkgs[path] = false
            for _, l in ipairs(R.lines(path, HEAD)) do
                local p = l:match("^%s*package%s+([%w_.]+)")
                if p then
                    pkgs[path] = p
                    break
                end
            end
        end
        return pkgs[path] or nil
    end

    function R.header(path)
        if not heads[path] then heads[path] = imports.parse(R.lines(path, 300)) end
        return heads[path]
    end

    return R
end

return M
