-- User-facing navigation & editing actions.

local search = require("kotlin-lite.search")
local jars = require("kotlin-lite.jars")
local defs = require("kotlin-lite.defs")
local imports = require("kotlin-lite.imports")

local M = {}

local function cfg()
    return require("kotlin-lite.config").options
end

-------------------------------------------------------------------
-- shared helpers
-------------------------------------------------------------------

-- picker label: "[jar] path" for jar sources, project-relative otherwise
local function display(it)
    local f = it.filename
    if jars.is_jar(f) then
        f = "[jar] " .. (f:match("^" .. vim.pesc(cfg().cache_dir) .. "/[^/]+/(.*)$") or f)
    else
        f = vim.fn.fnamemodify(f, ":.")
    end
    return f .. ":" .. it.lnum .. "  " .. it.text
end
M.display = display

-- where gd was invoked, for the tag stack: { win, item = settagstack item }
local function tag_origin(name)
    local from = vim.fn.getpos(".")
    from[1] = vim.api.nvim_get_current_buf()
    return { win = vim.api.nvim_get_current_win(), item = { tagname = name, from = from } }
end

-- push a gd jump on the tag stack so <C-t> / :tags / :pop work like with LSP
local function push_tag(origin)
    if vim.api.nvim_win_is_valid(origin.win) then
        vim.fn.settagstack(origin.win, { items = { origin.item } }, "t")
    end
end

local function jump(it)
    vim.cmd("normal! m'")
    vim.cmd.edit(vim.fn.fnameescape(it.filename))
    pcall(vim.api.nvim_win_set_cursor, 0, { it.lnum, math.max((it.col or 1) - 1, 0) })
    vim.cmd("normal! zvzz")
end
M._jump, M._tag_origin, M._push_tag = jump, tag_origin, push_tag

-- the match the file header points at (imports / package), then project over jar
local function best(items, word)
    imports.rank_items(imports.current(), word, items)
    local pick
    for _, it in ipairs(items) do
        local better = not pick or it.rank < pick.rank
            or (it.rank == pick.rank and jars.is_jar(pick.filename) and not jars.is_jar(it.filename))
        if better then pick = it end
    end
    return pick
end

-------------------------------------------------------------------
-- goto definition (gd)
-------------------------------------------------------------------

M._import_target = imports.import_target

-- go to implementation (gri): subtypes / overrides / actuals, see impl.lua
function M.goto_implementation()
    require("kotlin-lite.impl").goto_implementation()
end

local function notify_err(res)
    vim.notify("kotlin-lite: " .. res.err, res.level or vim.log.levels.WARN)
end

local function go_to(res, origin, prompt)
    local function go(it)
        push_tag(origin)
        jump(it)
    end
    if res.err then return notify_err(res) end
    if res.here then
        -- same buffer: no :edit, keep the view
        push_tag(origin)
        vim.cmd("normal! m'")
        vim.api.nvim_win_set_cursor(0, { res.jump.lnum, res.jump.col - 1 })
        vim.cmd("normal! zv")
        return
    end
    if res.jump then return go(res.jump) end
    require("kotlin-lite.picker").select(defs.rows(res.pool), { prompt = prompt .. ": " .. res.word }, go)
end

function M.goto_definition()
    local word = vim.fn.expand("<cword>")
    if word == "" then return end
    local origin = tag_origin(word)
    require("kotlin-lite.resolve").at_cursor(function(res) go_to(res, origin, "Definition") end)
end

function M.goto_super()
    local word = vim.fn.expand("<cword>")
    if word == "" then return end
    local origin = tag_origin(word)
    local resolve = require("kotlin-lite.resolve")
    resolve.run(function(ctx, E) go_to(resolve.super_at(ctx, E), origin, "Super") end, "go to super")
end

function M.goto_type_definition()
    local word = vim.fn.expand("<cword>")
    if word == "" then return end
    local origin = tag_origin(word)
    local resolve = require("kotlin-lite.resolve")
    resolve.run(function(ctx, E) go_to(resolve.type_at(ctx, E), origin, "Type") end, "grt")
end

-------------------------------------------------------------------
-- 'tagfunc': <C-]>, <C-w>], g], :tag, :ptag, <C-w>} through gd's lookup
-------------------------------------------------------------------

-- Same resolution as gd, as tag items ordered best first (<C-]> takes the
-- first). Blocking rg: Vim needs the answer at once. Insert-mode completion
-- and :tag /regex fall back to tags files.
function M.tagfunc(pattern, flags)
    if flags:find("[ir]") or not pattern:match("^[%a_][%w_]*$") then return vim.NIL end
    local res = require("kotlin-lite.resolve").sync(pattern, flags:find("c") ~= nil)
    local function tag(it)
        return {
            name = pattern,
            filename = it.filename,
            cmd = ("/\\%%%dl\\%%%dc/"):format(it.lnum, it.col or 1),
        }
    end
    if res.jump then return { tag(res.jump) } end
    local out = {}
    for _, row in ipairs(defs.rows(res.pool or {})) do -- best first
        out[#out + 1] = tag(row.data)
    end
    return out
end

-------------------------------------------------------------------
-- hover (K) and signature help (gK)
-------------------------------------------------------------------

-- KDoc + annotations + signature, cut until parens balance
local function doc_block(lines, lnum)
    local s, e = lnum, lnum
    if lines[lnum]:find("%(") then
        local bal = 0
        for i = lnum, math.min(lnum + 15, #lines) do
            local _, o = lines[i]:gsub("%(", "")
            local _, c = lines[i]:gsub("%)", "")
            bal = bal + o - c
            e = i
            if bal <= 0 then break end
        end
    end
    while s > 1 and lines[s - 1]:match("^%s*@") do s = s - 1 end
    if s > 1 and lines[s - 1]:match("%*/%s*$") then
        local k = s - 1
        while k > 1 and not lines[k]:match("/%*%*") do k = k - 1 end
        if lines[k]:match("/%*%*") then s = k end
    end
    local block = {}
    for i = s, e do table.insert(block, lines[i]) end
    return block, s
end

-- `lines`: the file's text when at hand (a buffer's); `head`: lines above
local function show_float(it, lines, head)
    if not lines then
        local ok, read = pcall(vim.fn.readfile, it.filename)
        if not ok then return end
        lines = read
    end
    if not lines[it.lnum] then return end
    local block = vim.list_extend(head or {}, (doc_block(lines, it.lnum)))
    table.insert(block, "")
    table.insert(block, "-- " .. display(it))
    vim.lsp.util.open_floating_preview(block, "kotlin", {
        border = "rounded",
        max_width = 100,
        max_height = 30,
        focus_id = "kotlin-lite-hover",
    })
end

-- what gd resolves to; of several, the best-ranked
function M.hover()
    local buf = vim.api.nvim_get_current_buf()
    local resolve = require("kotlin-lite.resolve")
    resolve.run(function(ctx, E)
        local res = resolve.resolve(ctx, E)
        if res.err then return notify_err(res) end
        if res.resources then
            return vim.lsp.util.open_floating_preview(require("kotlin-lite.resources").hover_lines(res), "", {
                border = "rounded", max_width = 100, max_height = 30, focus_id = "kotlin-lite-hover",
            })
        end
        local it = res.jump or defs.rows(res.pool)[1].data
        local lines
        if res.here and vim.api.nvim_buf_is_valid(buf) then
            lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        end
        local head
        if it.lambda then
            local t = resolve.it_type(ctx, E, it.lambda)
            head = { t and ("it: " .. t.name) or "it", "" }
        end
        show_float(it, lines, head)
    end, "K")
end

local SIG_NS = vim.api.nvim_create_namespace("kotlin-lite-signature")

-- signature of the call around the cursor, active parameter highlighted
function M.signature_help()
    local resolve = require("kotlin-lite.resolve")
    local buf = vim.api.nvim_get_current_buf()
    local cur = vim.api.nvim_win_get_cursor(0)
    local call = resolve.call_at(resolve.base(buf), cur[1], cur[2])
    if not call or not call.ctx then return M.hover() end
    resolve.run(function(ctx, E)
        local res = resolve.resolve(ctx, E)
        if res.err then return notify_err(res) end
        local it = res.jump or defs.rows(res.pool)[1].data
        local lines = it.filename == ctx.path and ctx.sc.lines or vim.fn.readfile(it.filename)
        if not lines[it.lnum] then return end
        local block, first = doc_block(lines, it.lnum)
        local spans = resolve.param_spans(lines, it.lnum, (it.col or 1) - 1)
        local active
        for i, sp in ipairs(spans) do
            if (call.name and sp.name == call.name) or (not call.name and i == call.index + 1) then active = sp end
        end
        table.insert(block, "")
        table.insert(block, "-- " .. display(it))
        local fbuf = vim.lsp.util.open_floating_preview(block, "kotlin", {
            border = "rounded",
            max_width = 100,
            max_height = 30,
            focus_id = "kotlin-lite-signature",
        })
        if active and fbuf and active.lnum >= first and active.lnum < first + #block then
            vim.api.nvim_buf_set_extmark(fbuf, SIG_NS, active.lnum - first, active.s, {
                end_col = active.e, hl_group = "LspSignatureActiveParameter",
            })
        end
    end, "gK", call.ctx)
end

-------------------------------------------------------------------
-- find usages (gr) -> quickfix at the bottom
-------------------------------------------------------------------
local function show_usages(word, items)
    if #items == 0 then
        vim.notify("kotlin-lite: no usages of '" .. word .. "' found", vim.log.levels.INFO)
        return
    end
    vim.fn.setqflist({}, " ", { title = "Usages: " .. word, items = items })
    vim.cmd("botright copen 12")
end

-- unresolved: every mention outside comments
function M.find_usages()
    local word = vim.fn.expand("<cword>")
    if word == "" then return end
    local resolve = require("kotlin-lite.resolve")
    resolve.run(function(ctx, E)
        local u = require("kotlin-lite.usages").find(ctx, E)
        if u.items then return show_usages(word, u.items) end
        local items = E.run({ "-w", "-e", word }, { search.root() })
        show_usages(word, vim.tbl_filter(function(it) return not search.is_comment_text(it.text) end, items))
    end, "gu")
end

-------------------------------------------------------------------
-- rename (<leader>cr): word search & replace, scoped to `dir`
-------------------------------------------------------------------

-- rg -w `word` under `dir`, confirm, then cfdo replace word -> new
local function replace_word(word, new, dir, scope_label)
    search.rg({ "-w", "-e", word }, { dir }, function(items)
        if #items == 0 then
            vim.notify("kotlin-lite: nothing to replace", vim.log.levels.INFO)
            return
        end
        local files = {}
        for _, it in ipairs(items) do files[it.filename] = true end
        local msg = ("Replace %d occurrences of '%s' -> '%s' in %d files (%s)?")
            :format(#items, word, new, vim.tbl_count(files), scope_label)
        if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then return end

        local cur_buf = vim.api.nvim_get_current_buf()
        local view = vim.fn.winsaveview()
        vim.fn.setqflist({}, " ", { title = "Rename: " .. word .. " -> " .. new, items = items })
        vim.cmd(("silent! cfdo %%s/\\V\\<%s\\>/%s/ge | update"):format(word, new))
        if vim.api.nvim_buf_is_valid(cur_buf) then
            vim.api.nvim_set_current_buf(cur_buf)
            vim.fn.winrestview(view)
        end
        vim.notify(("kotlin-lite: replaced in %d files"):format(vim.tbl_count(files)), vim.log.levels.INFO)
    end)
end

local function apply_rename(items, new, save)
    local by_file = {}
    for _, it in ipairs(items) do
        by_file[it.filename] = by_file[it.filename] or {}
        table.insert(by_file[it.filename], it)
    end
    for path, list in pairs(by_file) do
        local b = vim.fn.bufadd(path)
        vim.fn.bufload(b)
        table.sort(list, function(a, c) return a.lnum > c.lnum or (a.lnum == c.lnum and a.col > c.col) end)
        for _, it in ipairs(list) do
            vim.api.nvim_buf_set_text(b, it.lnum - 1, it.col - 1, it.lnum - 1, it.end_col - 1, { it.insert or new })
        end
        if save then vim.api.nvim_buf_call(b, function() vim.cmd("silent update") end) end
    end
    return vim.tbl_count(by_file)
end

-- a local in place; anything else confirmed and saved
function M.rename()
    local word = vim.fn.expand("<cword>")
    if word == "" then return end
    vim.ui.input({ prompt = "Rename '" .. word .. "' -> ", default = word }, function(new)
        if not new or new == "" or new == word then return end
        if not new:match("^[%a_][%w_]*$") then
            vim.notify("kotlin-lite: '" .. new .. "' is not a valid identifier", vim.log.levels.ERROR)
            return
        end
        local resolve = require("kotlin-lite.resolve")
        resolve.run(function(ctx, E)
            local u = require("kotlin-lite.usages").find(ctx, E)
            if not u.items then return replace_word(word, new, search.root(), "project, unresolved") end
            if u.resource then
                vim.notify("kotlin-lite: " .. u.resource .. " is a resource, rename it in the xml", vim.log.levels.WARN)
                return
            end
            if jars.is_jar(u.decl.filename) then
                vim.notify("kotlin-lite: '" .. word .. "' is declared in a library", vim.log.levels.WARN)
                return
            end
            if u.decl.lambda then
                local brace = u.decl.col + 1
                table.insert(u.items, {
                    filename = u.decl.filename, lnum = u.decl.lnum, col = brace, end_col = brace,
                    insert = " " .. new .. " ->",
                })
            end
            if u.here_only then return apply_rename(u.items, new, false) end
            local files = {}
            for _, it in ipairs(u.items) do files[it.filename] = true end
            local msg = ("Rename %d occurrences of '%s' -> '%s' in %d files?")
                :format(#u.items, word, new, vim.tbl_count(files))
            if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then return end
            local n = apply_rename(u.items, new, true)
            vim.notify(("kotlin-lite: renamed in %d files"):format(n), vim.log.levels.INFO)
        end, "rename")
    end)
end

-------------------------------------------------------------------
-- rename file (<leader>cR): move the file and, for a same-named
-- top-level entity, offer a module-scoped symbol rename
-------------------------------------------------------------------

-- kind of a top-level class/interface/object/fun named `name`, or nil.
-- Anchored at column 0 (optional lowercase modifiers) so nested decls are ignored.
local function toplevel_entity(lines, name)
    local esc = vim.pesc(name)
    for _, l in ipairs(lines) do
        if l:match("^%S") then -- top-level only: no indentation
            for _, k in ipairs({ "class", "interface", "object" }) do
                if l:match("^[%l ]*" .. k .. "%s+" .. esc .. "%f[%W]") then return k end
            end
            if l:match("^[%l ]*fun%s+" .. esc .. "%s*[(<]") then return "fun" end
        end
    end
    return nil
end
M._toplevel_entity = toplevel_entity

local function read_lines(path)
    local b = vim.fn.bufnr("^" .. path .. "$")
    if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
        return vim.api.nvim_buf_get_lines(b, 0, -1, false)
    end
    local ok, l = pcall(vim.fn.readfile, path)
    return ok and l or {}
end

-- Rename `old_path`; keep an open buffer attached, refresh via on_done.
function M.rename_path(old_path, on_done)
    if not old_path or old_path == "" then
        vim.notify("kotlin-lite: no file to rename", vim.log.levels.WARN)
        return
    end
    local dir = vim.fn.fnamemodify(old_path, ":h")
    local ext = vim.fn.fnamemodify(old_path, ":e")
    local old_base = vim.fn.fnamemodify(old_path, ":t:r")

    vim.ui.input({ prompt = "Rename file -> ", default = old_base }, function(new_base)
        if not new_base or new_base == "" or new_base == old_base then return end
        local new_name = ext ~= "" and (new_base .. "." .. ext) or new_base
        local new_path = dir .. "/" .. new_name
        if vim.fn.filereadable(new_path) == 1 then
            vim.notify("kotlin-lite: '" .. new_name .. "' already exists", vim.log.levels.ERROR)
            return
        end

        -- detect the entity before moving (read from buffer or disk)
        local entity = ext == "kt" and toplevel_entity(read_lines(old_path), old_base) or nil

        local bufnr = vim.fn.bufnr("^" .. old_path .. "$")
        if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
            vim.api.nvim_buf_call(bufnr, function()
                vim.cmd("keepalt saveas! " .. vim.fn.fnameescape(new_path))
            end)
            vim.fn.delete(old_path)
            local stale = vim.fn.bufnr("^" .. old_path .. "$")
            if stale ~= -1 and stale ~= bufnr then
                pcall(vim.api.nvim_buf_delete, stale, { force = true })
            end
        else
            vim.fn.mkdir(dir, "p")
            if vim.fn.rename(old_path, new_path) ~= 0 then
                vim.notify("kotlin-lite: rename failed", vim.log.levels.ERROR)
                return
            end
        end
        vim.notify("kotlin-lite: renamed to " .. new_name, vim.log.levels.INFO)
        if on_done then on_done(new_path) end

        if entity and new_base:match("^[%a_][%w_]*$") then
            local q = ("Also rename %s '%s' -> '%s' in the module?"):format(entity, old_base, new_base)
            if vim.fn.confirm(q, "&Yes\n&No", 2) == 1 then
                local module_root = vim.fs.root(new_path, { "build.gradle.kts", "build.gradle" }) or search.root()
                replace_word(old_base, new_base, module_root, "module")
            end
        end
    end)
end

function M.rename_file()
    M.rename_path(vim.api.nvim_buf_get_name(0))
end

-------------------------------------------------------------------
-- file structure (<leader>cs): a scope-aware outline
--
-- Shows top-level val/var/fun/class/interface/object, class members (fun +
-- public val/var incl. primary-constructor properties) and companion objects.
-- Hides function locals, plain parameters, and private/protected members.
-------------------------------------------------------------------

local MODIFIERS = {
    public = true, private = true, protected = true, internal = true,
    open = true, final = true, abstract = true, sealed = true, data = true,
    enum = true, annotation = true, inner = true, value = true, inline = true,
    infix = true, operator = true, suspend = true, override = true,
    lateinit = true, const = true, external = true, tailrec = true,
    companion = true, actual = true, expect = true,
}

-- consume leading modifier words; return the modifier set and the remainder
local function split_modifiers(s)
    local mods = {}
    while true do
        local w, rest = s:match("^(%a+)%s+(.*)$")
        if w and MODIFIERS[w] then mods[w] = true; s = rest else break end
    end
    return mods, s
end

local function visibility(mods)
    if mods.private then return "private" end
    if mods.protected then return "protected" end
    if mods.internal then return "internal" end
    return "public"
end

-- inside of the first balanced (...) in `text`, or nil
local function first_paren_group(text)
    local i = text:find("(", 1, true)
    if not i then return nil end
    local depth = 0
    for j = i, #text do
        local c = text:sub(j, j)
        if c == "(" then depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then return text:sub(i + 1, j - 1) end
        end
    end
    return nil
end

-- split on top-level commas (ignoring <>, (), [] nesting)
local function split_params(inside)
    local params, depth, buf = {}, 0, ""
    for k = 1, #inside do
        local c = inside:sub(k, k)
        if c == "<" or c == "(" or c == "[" then depth = depth + 1; buf = buf .. c
        elseif c == ">" or c == ")" or c == "]" then depth = depth - 1; buf = buf .. c
        elseif c == "," and depth == 0 then params[#params + 1] = buf; buf = ""
        else buf = buf .. c end
    end
    if buf:match("%S") then params[#params + 1] = buf end
    return params
end

-- a declaration at the start of `raw`, or nil
local function detect_decl(raw)
    local s = raw:gsub("^%s+", ""):gsub("^@[%w_.]+%s*", "")
    local mods, rest = split_modifiers(s)
    local vis = visibility(mods)

    if mods.companion and rest:match("^object%f[%W]") then
        return { kind = "companion", name = rest:match("^object%s+([%w_]+)") or "companion",
            vis = vis, opens_type = true, member_ok = true }
    end
    if rest:match("^fun%s+interface%f[%W]") then
        return { kind = "interface", name = rest:match("^fun%s+interface%s+([%w_]+)"),
            vis = vis, opens_type = true, top_ok = true, member_ok = true }
    end

    local kw = rest:match("^(%a+)%f[%W]")
    if kw == "class" or kw == "interface" or kw == "object" then
        return { kind = kw, name = rest:match("^%a+%s+([%w_]+)"),
            vis = vis, opens_type = true, top_ok = true, member_ok = true }
    elseif kw == "fun" then
        return { kind = "fun", name = rest:match("([%w_]+)%s*%("),
            vis = vis, top_ok = true, member_ok = true }
    elseif kw == "val" or kw == "var" then
        local body = rest:gsub("^va[lr]%s+", ""):gsub("^<[^>]*>%s*", "")
        local name = body:match("^([%w_]+)%s*[:=]")
            or body:match("^([%w_]+)%s+by%f[%W]")
            or body:match("([%w_]+)%s*[:=]")
            or body:match("^([%w_]+)")
        return { kind = "field", name = name, vis = vis, top_ok = true, member_ok = true }
    end
    return nil
end

-- val/var properties of a primary constructor; `lines` masked
local function ctor_props(lines, start_lnum)
    local code, depth, started, endl = {}, 0, false, start_lnum
    for i = start_lnum, math.min(#lines, start_lnum + 30) do
        local c = lines[i]
        code[#code + 1] = c
        for ch in c:gmatch("[()]") do
            if ch == "(" then depth = depth + 1; started = true else depth = depth - 1 end
        end
        endl = i
        if started and depth <= 0 then break end
        if not started and c:find("{") then break end -- body before any ctor
    end
    local inside = started and first_paren_group(table.concat(code, "\n")) or nil
    if not inside then return {} end

    local out = {}
    for _, p in ipairs(split_params(inside)) do
        local ps = p:gsub("^%s+", ""):gsub("^@[%w_.]+%s*", "")
        local mods, rest = split_modifiers(ps)
        if rest:match("^va[lr]%f[%W]") then
            local nm = rest:match("^va[lr]%s+([%w_]+)")
            if nm then
                local lnum, col = start_lnum, 0
                for i = start_lnum, endl do
                    local idx = lines[i]:find("%f[%w]" .. nm .. "%f[%W]")
                    if idx then lnum, col = i, idx - 1; break end
                end
                out[#out + 1] = { name = nm, lnum = lnum, col = col, vis = visibility(mods) }
            end
        end
    end
    return out
end

-- Outline items for `lines`, in source order.
--
-- Tracks brace scopes ("type" = class/interface/object body, else block/func) and
-- paren depth. Declarations are only read at the start of a line outside parens,
-- so multi-line constructor/parameter lists don't leak in. `pending` carries a
-- declaration's body kind to its `{`, which may be lines away (multi-line ctor).
local function scan_symbols(lines)
    lines = require("kotlin-lite.scope").mask(lines)
    local items, scopes = {}, {} -- scopes: stack of "type"|"block"
    local paren, pending = 0, nil

    local function type_depth()
        local n = 0
        for _, s in ipairs(scopes) do if s == "type" then n = n + 1 end end
        return n
    end

    for lnum, raw in ipairs(lines) do
        if paren == 0 then
            local decl = detect_decl(raw)
            if decl and decl.name then
                local scope = scopes[#scopes]
                local show = (scope == nil and decl.top_ok) or (scope == "type" and decl.member_ok)
                if show then
                    items[#items + 1] = {
                        lnum = lnum, col = (raw:find(decl.name, 1, true) or 1) - 1,
                        kind = decl.kind, name = decl.name, vis = decl.vis, depth = type_depth(),
                    }
                end
                if decl.kind == "class" and (scope == nil or scope == "type") then
                    local d = type_depth() + 1
                    for _, pr in ipairs(ctor_props(lines, lnum)) do
                        items[#items + 1] = { lnum = pr.lnum, col = pr.col, kind = "field",
                            name = pr.name, vis = pr.vis, depth = d }
                    end
                end
                pending = decl.opens_type and "type" or "block"
            end
        end

        for i = 1, #raw do
            local c = raw:sub(i, i)
            if c == "(" then
                paren = paren + 1
            elseif c == ")" then
                if paren > 0 then paren = paren - 1 end
            elseif c == "{" then
                if paren == 0 and pending then
                    scopes[#scopes + 1], pending = pending, nil
                else
                    scopes[#scopes + 1] = "block"
                end
            elseif c == "}" and #scopes > 0 then
                scopes[#scopes] = nil
            end
        end
    end
    return items
end
M._scan_symbols = scan_symbols

function M.file_structure()
    local buf = vim.api.nvim_get_current_buf()
    local items = scan_symbols(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    if #items == 0 then
        vim.notify("kotlin-lite: no symbols in this file", vim.log.levels.INFO)
        return
    end
    local icons = cfg().symbols.icons
    -- UML-style visibility sigil (private -, protected #, internal ~); public is
    -- left blank -- the "fade" cue, since the picker rows can't be coloured.
    local sigil = { private = "-", protected = "#", internal = "~" }
    local fname = vim.api.nvim_buf_get_name(buf)
    local picks = {}
    for _, it in ipairs(items) do
        picks[#picks + 1] = {
            text = it.name, -- searched case-insensitively
            display = (icons[it.kind] or icons.field) .. " " .. (sigil[it.vis] or " ") .. " "
                .. string.rep("  ", it.depth or 0) .. it.name,
            data = it, file = fname, lnum = it.lnum, col = it.col, pos = { it.lnum, it.col },
        }
    end
    require("kotlin-lite.picker").select(picks, { prompt = "File structure" }, function(it)
        vim.cmd("normal! m'")
        vim.api.nvim_win_set_cursor(0, { it.lnum, it.col })
        vim.cmd("normal! zvzz")
    end)
end

-- rg args matching top-level (column 0) type & function declarations
local function toplevel_decl_args()
    local mod = [=[(?:public|private|protected|internal|open|final|abstract|sealed|]=]
        .. [=[data|enum|annotation|inner|value|companion|expect|actual|external)\s+]=]
    return {
        "-e", [=[^(?:]=] .. mod .. [=[)*(?:fun\s+)?(?:class|interface|object)\s+\w]=],
        "-e", [=[^(?:]=] .. mod .. [=[)*fun\s+(?:<[^>]*>\s*)?(?:[\w.<>?, ]+\.)?\w+\s*[(<]]=],
    }
end

-- IntelliJ Ctrl+N: one dialog, live search over top-level classes/interfaces/
-- objects/enums and top-level functions in the project.
function M.project_symbols()
    local wanted = { class = true, interface = true, object = true, ["fun"] = true }
    search.rg(toplevel_decl_args(), { search.root() }, function(items)
        local syms = {}
        for _, it in ipairs(items) do
            local decl = detect_decl(it.text)
            if decl and decl.name and wanted[decl.kind] then
                syms[#syms + 1] = {
                    filename = it.filename, lnum = it.lnum,
                    col = it.text:find(decl.name, 1, true) or 1,
                    kind = decl.kind, name = decl.name,
                }
            end
        end
        if #syms == 0 then
            vim.notify("kotlin-lite: no top-level symbols found", vim.log.levels.INFO)
            return
        end
        table.sort(syms, function(a, b)
            if a.name ~= b.name then return a.name < b.name end
            return a.filename < b.filename
        end)
        local icons = cfg().symbols.icons
        local picks = {}
        for _, s in ipairs(syms) do
            picks[#picks + 1] = {
                text = s.name, -- searched case-insensitively
                display = (icons[s.kind] or icons.field) .. "  " .. s.name
                    .. "   " .. vim.fn.fnamemodify(s.filename, ":."),
                data = s, file = s.filename, lnum = s.lnum, col = s.col, pos = { s.lnum, s.col },
            }
        end
        require("kotlin-lite.picker").select(picks, { prompt = "Project symbols" }, function(s)
            jump(s)
        end)
    end)
end

-------------------------------------------------------------------
-- recent files (IntelliJ Ctrl+E), best-effort across common pickers
-------------------------------------------------------------------
function M.recent_files()
    local ok, telescope = pcall(require, "telescope.builtin")
    if ok then return telescope.oldfiles() end
    local ok2, Snacks = pcall(require, "snacks")
    if ok2 and Snacks.picker then return Snacks.picker.recent() end
    vim.cmd("browse oldfiles")
end

-------------------------------------------------------------------
-- alternate file: X.kt <-> XTest.kt (by `Test` suffix, wherever it lives)
-------------------------------------------------------------------

local function open_file(path)
    vim.cmd("normal! m'")
    vim.cmd.edit(vim.fn.fnameescape(path))
end

-- conventional path to create the counterpart when none exists yet
local function mirror_path(dir, base, is_test)
    if is_test then
        local src = base:gsub("Test$", "")
        if dir:find("src/test/", 1, true) then
            return (dir:gsub("src/test/", "src/main/")) .. "/" .. src .. ".kt"
        end
        return dir .. "/" .. src .. ".kt"
    else
        if dir:find("src/main/", 1, true) then
            return (dir:gsub("src/main/", "src/test/")) .. "/" .. base .. "Test.kt"
        end
        return dir .. "/" .. base .. "Test.kt"
    end
end

function M.alternate_file()
    local path = vim.api.nvim_buf_get_name(0)
    if path == "" then
        vim.notify("kotlin-lite: no file", vim.log.levels.WARN)
        return
    end
    local dir = vim.fn.fnamemodify(path, ":h")
    local base = vim.fn.fnamemodify(path, ":t:r")
    local is_test = base:match("Test$") ~= nil
    local counterpart = is_test and base:gsub("Test$", "") or (base .. "Test")

    -- search the module for the existing counterpart (any directory layout)
    local root = vim.fs.root(path, { "build.gradle.kts", "build.gradle" }) or search.root()
    local hits = vim.fs.find(counterpart .. ".kt", { path = root, type = "file", limit = 50 })
    hits = vim.tbl_filter(function(p) return p ~= path end, hits)

    if #hits == 1 then
        open_file(hits[1])
        return
    elseif #hits > 1 then
        vim.ui.select(hits, {
            prompt = (is_test and "Source for " or "Test for ") .. base,
            format_item = function(p) return vim.fn.fnamemodify(p, ":.") end,
        }, function(choice)
            if choice then open_file(choice) end
        end)
        return
    end

    -- none found: offer to scaffold it at the conventional location
    local target = mirror_path(dir, base, is_test)
    local q = ("No %s found. Create %s?"):format(
        is_test and "source" or "test", vim.fn.fnamemodify(target, ":."))
    if vim.fn.confirm(q, "&Yes\n&No", 1) ~= 1 then return end
    vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")
    open_file(target)
end

-------------------------------------------------------------------
-- copy fully-qualified name (package + file name) to the + register
-------------------------------------------------------------------
-- nil for a local / unresolved symbol
local function symbol_fqname()
    local resolve = require("kotlin-lite.resolve")
    local cur = vim.api.nvim_win_get_cursor(0)
    local ctx = resolve.context_at(resolve.base(0), cur[1], cur[2])
    if not ctx or not ctx.code or ctx.s > cur[2] or require("kotlin-lite.scope").KEYWORDS[ctx.word] then
        return nil
    end
    local it = resolve.decided(resolve.run_sync(ctx, { stay = true }))
    local s = it and it.sym
    if not s or s.kind == "local" or s.kind == "param" then return nil end
    local parts = { s.pkg }
    for i = #s.owners, 1, -1 do parts[#parts + 1] = s.owners[i].name end
    parts[#parts + 1] = s.name
    return table.concat(parts, ".")
end

-- the symbol under the cursor, else the file
function M.copy_fqname()
    local name = vim.fn.expand("%:t:r")
    if name == "" then
        vim.notify("kotlin-lite: no file name", vim.log.levels.WARN)
        return
    end
    local pkg
    for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        pkg = l:match("^%s*package%s+([%w_.]+)")
        if pkg then break end
    end
    local fq = symbol_fqname() or (pkg and (pkg .. "." .. name) or name)
    vim.fn.setreg("+", fq)
    vim.notify("kotlin-lite: copied " .. fq, vim.log.levels.INFO)
    return fq
end

-------------------------------------------------------------------
-- format the whole buffer through `formatprg` (ktlint by default)
-------------------------------------------------------------------
-- Always whole-file: ktlint reindents from column 0, so piping a partial range
-- would flatten nested declarations. stdout replaces the buffer; stderr (logs)
-- is dropped.
function M.format_buffer()
    local prg = cfg().formatprg
    if not prg or prg == "" then
        vim.notify("kotlin-lite: no formatter configured (formatprg)", vim.log.levels.WARN)
        return
    end
    local buf = vim.api.nvim_get_current_buf()
    local input = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"

    local ok, res = pcall(function()
        return vim.system(vim.split(prg, "%s+"), { stdin = input, text = true }):wait()
    end)
    if not ok then
        vim.notify("kotlin-lite: formatter failed to start: " .. tostring(res), vim.log.levels.ERROR)
        return
    end
    if (res.stdout == nil or res.stdout == "") and res.code ~= 0 then
        vim.notify("kotlin-lite: format failed\n" .. (res.stderr or ""), vim.log.levels.ERROR)
        return
    end

    local out = vim.split(res.stdout, "\n")
    if out[#out] == "" then table.remove(out) end -- drop trailing newline
    if vim.deep_equal(out, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
        return -- already formatted; don't touch undo/modified
    end
    local view = vim.fn.winsaveview()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
    vim.fn.winrestview(view)
end

-------------------------------------------------------------------
-- auto-import the symbol under the cursor (Alt+Enter)
-------------------------------------------------------------------
function M.auto_import_under_cursor()
    require("kotlin-lite.autoimport").run()
end

-------------------------------------------------------------------
-- file finder (IntelliJ Ctrl+N), best-effort across common pickers
-------------------------------------------------------------------
function M.find_files()
    local ok, telescope = pcall(require, "telescope.builtin")
    if ok then return telescope.find_files() end
    local ok2, Snacks = pcall(require, "snacks")
    if ok2 and Snacks.picker then return Snacks.picker.files() end
    vim.cmd("edit .")
end

return M
