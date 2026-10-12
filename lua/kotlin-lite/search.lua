-- Search primitives: ripgrep (rust regex) for the project, matchbufline (vim
-- regex) for the current buffer.

local M = {}

local function jars()
    return require("kotlin-lite.jars")
end

-- project root = nvim's cwd
function M.root()
    return vim.fn.getcwd()
end

-------------------------------------------------------------------
-- ripgrep declaration patterns (rust regex)
-------------------------------------------------------------------

function M.decl_patterns(w)
    local recv = [=[([\w.<>?,\s]+\.)?]=] -- extension receiver: fun Iterable<T>.map
    return {
        -- fun / suspend fun / fun <T> / fun Receiver.name(
        [=[\bfun\s+(<[^>]*>\s+)?]=] .. recv .. w .. [=[\s*[(<]]=],
        -- class / data class / enum class / interface / object / typealias
        [=[\b(class|interface|object|typealias)\s+]=] .. w .. [=[\b]=],
        -- val/var name: T | = ... | by ... (incl. constructor params)
        [=[\b(val|var)\s+(<[^>]*>\s+)?]=] .. recv .. w .. [=[(\s*[:=]|\s+by\b|\s*$)]=],
    }
end

-- declaration patterns as `-e pat -e pat ...` rg args
function M.decl_args(word)
    local args = {}
    for _, p in ipairs(M.decl_patterns(word)) do
        vim.list_extend(args, { "-e", p })
    end
    return args
end

local function rg_cmd(extra, dirs)
    local cmd = { "rg", "--vimgrep", "--no-messages", "-t", "kotlin", "-t", "java" }
    vim.list_extend(cmd, extra)
    vim.list_extend(cmd, dirs)
    return cmd
end

-- rg --vimgrep output -> quickfix-style items deduped by file:line
local function parse(stdout)
    local items, seen = {}, {}
    for _, line in ipairs(vim.split(stdout or "", "\n", { trimempty = true })) do
        local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
        if file then
            local key = file .. ":" .. lnum
            if not seen[key] then
                seen[key] = true
                table.insert(items, {
                    filename = file,
                    lnum = tonumber(lnum),
                    col = tonumber(col),
                    text = vim.trim(text),
                })
            end
        end
    end
    return items
end

-- run rg, callback with the items on the main loop
function M.rg(extra, dirs, cb)
    vim.system(rg_cmd(extra, dirs), { text = true }, function(res)
        local items = parse(res.stdout)
        vim.schedule(function() cb(items) end)
    end)
end

-- blocking rg, for callers that must answer at once (tagfunc)
function M.rg_sync(extra, dirs)
    return parse(vim.system(rg_cmd(extra, dirs), { text = true }):wait().stdout)
end

-- project root + every extracted jar source tree
function M.search_dirs()
    local dirs = { M.root() }
    vim.list_extend(dirs, jars().jar_dirs())
    return dirs
end

-------------------------------------------------------------------
-- in-buffer declaration search (vim regex via matchbufline)
-------------------------------------------------------------------

-- vim-regex decl patterns for `w`, \zs sets match start at the name.
-- \C forces case-sensitivity (Kotlin ids differ by case; user 'ignorecase' must
-- not make `Circle` match `circle`).
function M.buffer_decl_patterns(w)
    local pats = {
        -- val / var (incl. generics and extension receiver)
        [=[\<\%(val\|var\)\s\+\%(<[^>]*>\s\+\)\?\%([A-Za-z0-9_.<>?, ]\+\.\)\?\zs\<]=] .. w .. [=[\>]=],
        -- destructuring declaration: val (a, b) = ...
        [=[\<\%(val\|var\)\s\+(\%(\s*[A-Za-z0-9_]\+\s*,\)*\s*\zs\<]=] .. w .. [=[\>]=],
        -- fun declaration (incl. generics and extension receiver)
        [=[\<fun\s\+\%(<[^>]*>\s\+\)\?\%([A-Za-z0-9_.<>?, ]\+\.\)\?\zs\<]=] .. w .. [=[\>\ze\s*(]=],
        -- class / interface / object / typealias
        [=[\<\%(class\|interface\|object\|typealias\)\s\+\zs\<]=] .. w .. [=[\>]=],
        -- function / constructor / catch parameter: "(name:" or ", name:"
        [=[[(,]\s*\%(vararg\s\+\|noinline\s\+\|crossinline\s\+\)\?\zs\<]=] .. w .. [=[\>\ze\s*:]=],
        -- parameter on its own line in a multi-line signature: "name: Type,"
        [=[^\s*\zs\<]=] .. w .. [=[\>\ze\s*:[^:]]=],
        -- lambda parameter: "name ->" or "name: Type ->"
        [=[\zs\<]=] .. w .. [=[\>\ze\s*\%(:\s*[A-Za-z0-9_.<>?]\+\s*\)\?->]=],
        -- for-loop variable: "for (name in ...)"
        [=[\<for\s*(\s*\zs\<]=] .. w .. [=[\>\ze\s\+in\>]=],
    }
    for i, p in ipairs(pats) do
        pats[i] = [=[\C]=] .. p
    end
    return pats
end

-- line text opens with //, /* or a KDoc "*"
function M.is_comment_text(line)
    local stripped = line:match("^%s*(.*)$") or ""
    return stripped:sub(1, 2) == "//" or stripped:sub(1, 1) == "*" or stripped:sub(1, 2) == "/*"
end

function M.is_comment_line(buf, lnum)
    return M.is_comment_text(vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or "")
end

-- `word`'s declaration in the current buffer: nearest one at/above the cursor,
-- else the first below. Returns { lnum, col (0-based) } or nil.
function M.decl_in_buffer(word)
    local buf = vim.api.nvim_get_current_buf()
    local cur = vim.api.nvim_win_get_cursor(0)
    local cur_lnum, cur_col = cur[1], cur[2] -- col is 0-based

    local matches, seen = {}, {}
    for _, pat in ipairs(M.buffer_decl_patterns(word)) do
        local ok, found = pcall(vim.fn.matchbufline, buf, pat, 1, "$")
        if ok then
            for _, m in ipairs(found) do
                -- skip the decl the cursor sits on -> fall through to project search
                local on_cursor = m.lnum == cur_lnum
                    and cur_col >= m.byteidx
                    and cur_col < m.byteidx + #word
                local key = m.lnum .. ":" .. m.byteidx
                if not on_cursor and not seen[key] and not M.is_comment_line(buf, m.lnum) then
                    seen[key] = true
                    table.insert(matches, { lnum = m.lnum, col = m.byteidx })
                end
            end
        end
    end
    if #matches == 0 then return nil end

    table.sort(matches, function(a, b)
        if a.lnum ~= b.lnum then return a.lnum < b.lnum end
        return a.col < b.col
    end)
    local target = matches[1]
    for _, m in ipairs(matches) do
        if m.lnum <= cur_lnum then target = m else break end
    end
    return target
end

-- Jump to decl_in_buffer(word). Returns true if it jumped.
function M.find_decl_in_buffer(word)
    local target = M.decl_in_buffer(word)
    if not target then return false end
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { target.lnum, target.col })
    vim.cmd("normal! zv")
    return true
end

return M
