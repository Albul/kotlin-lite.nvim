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
                    indent = #text:match("^%s*"),
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

--- Parallel, cancellable rg: start / await / cancel / run. `async`: await
--- suspends the calling coroutine; else it blocks (tagfunc).
function M.engine(async)
    local E = {}
    if async then
        function E.spawn(cmd, read)
            local h = {}
            h.obj = vim.system(cmd, { text = true }, function(res)
                local items = read(res.stdout)
                vim.schedule(function()
                    h.items = items
                    local co = h.co
                    h.co = nil
                    if co then
                        local ok, err = coroutine.resume(co, items)
                        if not ok then
                            vim.notify("kotlin-lite: " .. tostring(err), vim.log.levels.ERROR)
                        end
                    end
                end)
            end)
            return h
        end
        function E.await(h)
            if h.items then return h.items end
            h.co = coroutine.running()
            return coroutine.yield()
        end
    else
        function E.spawn(cmd, read)
            return { obj = vim.system(cmd, { text = true }), read = read }
        end
        function E.await(h)
            h.items = h.items or h.read(h.obj:wait().stdout)
            return h.items
        end
    end
    function E.start(extra, dirs)
        return E.spawn(rg_cmd(extra, dirs), parse)
    end
    function E.cancel(h)
        if not h.items then pcall(h.obj.kill, h.obj, 15) end
    end
    function E.run(extra, dirs)
        return E.await(E.start(extra, dirs))
    end
    --- files matching any of `globs` -> items at their first line
    function E.files(globs, dirs)
        local cmd = { "rg", "--files", "--no-messages" }
        for _, g in ipairs(globs) do vim.list_extend(cmd, { "-g", g }) end
        vim.list_extend(cmd, dirs)
        return E.await(E.spawn(cmd, function(stdout)
            local items = {}
            for _, f in ipairs(vim.split(stdout or "", "\n", { trimempty = true })) do
                items[#items + 1] = { filename = f, lnum = 1, col = 1, text = vim.fs.basename(f) }
            end
            return items
        end))
    end
    return E
end

--- Move a hit's column to `word` (when spelled the same in it), set end_col.
function M.at_word(it, word)
    local s = it.text:find(word, it.col - it.indent, true)
    if s then it.col = s + it.indent end
    it.end_col = it.col + #word
    return it
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

-- vim-regex decl patterns for `w` (\zs at the name), tagged with their kind
-- \C forces case-sensitivity (Kotlin ids differ by case; user 'ignorecase' must
-- not make `Circle` match `circle`).
function M.buffer_decl_patterns(w)
    local pats = {
        -- val / var (incl. generics and extension receiver)
        { "val", [=[\<\%(val\|var\)\s\+\%(<[^>]*>\s\+\)\?\%([A-Za-z0-9_.<>?, ]\+\.\)\?\zs\<]=] .. w .. [=[\>]=] },
        -- destructuring declaration: val (a, b) = ...
        { "val", [=[\<\%(val\|var\)\s\+(\%(\s*[A-Za-z0-9_]\+\s*,\)*\s*\zs\<]=] .. w .. [=[\>]=] },
        -- fun declaration (incl. generics and extension receiver)
        { "fun", [=[\<fun\s\+\%(<[^>]*>\s\+\)\?\%([A-Za-z0-9_.<>?, ]\+\.\)\?\zs\<]=] .. w .. [=[\>\ze\s*(]=] },
        -- class / interface / object / typealias
        { "type", [=[\<\%(class\|interface\|object\|typealias\)\s\+\zs\<]=] .. w .. [=[\>]=] },
        -- function / constructor / catch parameter: "(name:" or ", name:"
        { "param", [=[[(,]\s*\%(vararg\s\+\|noinline\s\+\|crossinline\s\+\)\?\zs\<]=] .. w .. [=[\>\ze\s*:]=] },
        -- parameter on its own line in a multi-line signature: "name: Type,"
        { "param", [=[^\s*\zs\<]=] .. w .. [=[\>\ze\s*:[^:]]=] },
        -- lambda parameter: "name ->" or "name: Type ->"
        { "lambda", [=[\zs\<]=] .. w .. [=[\>\ze\s*\%(:\s*[A-Za-z0-9_.<>?]\+\s*\)\?->]=] },
        -- for-loop variable: "for (name in ...)"
        { "param", [=[\<for\s*(\s*\zs\<]=] .. w .. [=[\>\ze\s\+in\>]=] },
    }
    for i, p in ipairs(pats) do
        pats[i] = { kind = p[1], re = [=[\C]=] .. p[2] }
    end
    return pats
end

-- line text opens with //, /* or a KDoc "*"
function M.is_comment_text(line)
    local stripped = line:match("^%s*(.*)$") or ""
    return stripped:sub(1, 2) == "//" or stripped:sub(1, 1) == "*" or stripped:sub(1, 2) == "/*"
end

--- `word`'s declaration in the current buffer visible at the cursor (or
--- lnum, 0-based col `s`) by lexical scope; in a comment, the nearest one.
function M.decl_in_buffer(word, sc, lnum, s)
    local scope = require("kotlin-lite.scope")
    local buf = vim.api.nvim_get_current_buf()
    sc = sc or scope.scan(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    if not lnum then
        local cur = vim.api.nvim_win_get_cursor(0)
        local line = vim.api.nvim_get_current_line()
        lnum, s = cur[1], cur[2]
        while s > 0 and line:sub(s, s):match("[%w_]") do s = s - 1 end
        if line:sub(s + 1, s + #word) ~= word then
            s = (line:find(word, cur[2] + 1, true) or cur[2] + 1) - 1
        end
    end
    local here = scope.key(lnum, s)

    local decls = scope.decls(sc, word)
    local d = scope.visible(decls, here, here)
    if d then return d end

    if (sc.mask[lnum] or ""):sub(s + 1, s + #word) == word then return nil end
    -- comment: nearest above, else first below
    local target
    for _, x in ipairs(decls) do
        if scope.key(x.lnum, x.col) ~= here then
            if not target or x.lnum <= lnum then target = x end
            if x.lnum > lnum then break end
        end
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
