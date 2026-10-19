-- Rename preview: every occurrence a rename would change, by file, each with a
-- checkbox. Guesses (the receiver's type unknown) start unchecked; <CR>
-- applies what is checked. Files with unsaved changes get the edit but are
-- not written: the user's own changes are theirs to save.

local M = {}

M.ns = vim.api.nvim_create_namespace("kotlin-lite-rename-preview")

local HELP = "<Space> toggle (a line, a file, a visual range)  a all / none  p context  <CR> apply  q cancel"

local function buf_of(path)
    local b = vim.fn.bufnr(path)
    return b ~= -1 and vim.api.nvim_buf_is_loaded(b) and b or nil
end

local function lines_of(path)
    local b = buf_of(path)
    if b then return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines or {}
end

--- paths among `items` whose buffer has unsaved changes
function M.unsaved(items)
    local out = {}
    for _, it in ipairs(items) do
        local b = buf_of(it.filename)
        if b and vim.bo[b].modified then out[it.filename] = true end
    end
    return out
end

-- items -> files { path, rel, items = { {it, line, sel} } } sorted by path, line, col
local function group(items)
    local by, files = {}, {}
    local sorted = vim.list_slice(items)
    table.sort(sorted, function(a, b)
        if a.filename ~= b.filename then return a.filename < b.filename end
        if a.lnum ~= b.lnum then return a.lnum < b.lnum end
        return a.col < b.col
    end)
    local cache = {}
    for _, it in ipairs(sorted) do
        local f = by[it.filename]
        if not f then
            f = { path = it.filename, rel = vim.fn.fnamemodify(it.filename, ":."), items = {} }
            by[it.filename], files[#files + 1] = f, f
            cache[it.filename] = lines_of(it.filename)
        end
        f.items[#f.items + 1] = { it = it, line = cache[it.filename][it.lnum] or "", sel = not it.guess }
    end
    return files
end

--- Open the preview of renaming `o.word` -> `o.new` at `items`;
--- o.on_apply(selected items) on <CR>. -> the preview buffer
function M.open(items, o)
    local files = group(items)
    local unsaved = M.unsaved(items)
    local guesses = 0
    for _, it in ipairs(items) do
        if it.guess then guesses = guesses + 1 end
    end

    vim.cmd("botright new")
    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
    vim.bo[buf].filetype = "kotlinlite-rename"
    vim.wo[win].wrap, vim.wo[win].number, vim.wo[win].relativenumber = false, false, false
    vim.wo[win].cursorline = true

    local rows -- buffer line -> { file = f } | { file = f, entry = e }

    local function count()
        local n = 0
        for _, f in ipairs(files) do
            for _, e in ipairs(f.items) do
                if e.sel then n = n + 1 end
            end
        end
        return n
    end

    local function render()
        local lines, marks = {}, {}
        rows = {}
        local function add(text, row)
            lines[#lines + 1] = text
            rows[#lines] = row
            return #lines - 1
        end
        local function mark(l, s, e, hl, extra)
            local opts = extra or {}
            if hl and e > s then opts.end_col, opts.hl_group = e, hl end
            if opts.hl_group or opts.virt_text then marks[#marks + 1] = { l, s, opts } end
        end

        local head = ("Rename %s → %s   %d of %d selected"):format(o.word, o.new, count(), #items)
        mark(add(head), 0, #head, "Title")
        mark(add(HELP), 0, #HELP, "Comment")
        if guesses > 0 then
            local g = ("[?] %d where the receiver's type is unknown: unchecked, check what you mean"):format(guesses)
            mark(add(g), 0, #g, "DiagnosticWarn")
        end
        if o.note then mark(add(o.note), 0, #o.note, "DiagnosticWarn") end

        for _, f in ipairs(files) do
            add("")
            local title = f.rel
            if unsaved[f.path] then title = title .. "   (unsaved changes: edited, not written)" end
            local l = add(title, { file = f })
            mark(l, 0, #f.rel, "Directory")
            if #title > #f.rel then mark(l, #f.rel, #title, "DiagnosticWarn") end
            for _, e in ipairs(f.items) do
                local lead = #(e.line:match("^%s*"))
                local code = e.line:sub(lead + 1)
                local prefix = ("  %s%s %5d  "):format(e.sel and "[x]" or "[ ]", e.it.guess and "?" or " ", e.it.lnum)
                l = add(prefix .. code, { file = f, entry = e })
                mark(l, 2, 5, e.sel and "DiagnosticOk" or "Comment")
                if e.it.guess then mark(l, 5, 6, "DiagnosticWarn") end
                local s = #prefix + (e.it.col - 1) - lead
                if not e.sel then
                    mark(l, #prefix, #prefix + #code, "Comment")
                elseif e.it.insert then
                    mark(l, s, s, nil, { virt_text = { { e.it.insert, "DiffAdd" } }, virt_text_pos = "inline" })
                elseif s >= #prefix then
                    local stop = s + (e.it.end_col - e.it.col)
                    mark(l, s, stop, "DiffDelete",
                        { virt_text = { { o.new, "DiffAdd" } }, virt_text_pos = "inline" })
                end
            end
        end

        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        vim.bo[buf].modified = false
        vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
        for _, m in ipairs(marks) do
            pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, m[1], m[2], m[3])
        end
    end

    -- toggle the entries of lines l1..l2 (a file line: its file); of several,
    -- any checked -> all unchecked, else all checked
    local function toggle(l1, l2)
        local entries = {}
        for l = l1, l2 do
            local r = rows[l]
            if r and r.entry then
                entries[#entries + 1] = r.entry
            elseif r then
                vim.list_extend(entries, r.file.items)
            end
        end
        if #entries == 0 then return end
        local any = false
        for _, e in ipairs(entries) do any = any or e.sel end
        for _, e in ipairs(entries) do e.sel = not any end
        render()
    end
    local function toggle_all()
        local all = true
        for _, f in ipairs(files) do
            for _, e in ipairs(f.items) do all = all and e.sel end
        end
        for _, f in ipairs(files) do
            for _, e in ipairs(f.items) do e.sel = not all end
        end
        render()
    end

    local function close()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end

    local ctx_win
    local function close_context()
        if ctx_win and vim.api.nvim_win_is_valid(ctx_win) then vim.api.nvim_win_close(ctx_win, true) end
        ctx_win = nil
    end

    local function map(mode, lhs, fn)
        vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true })
    end
    map("n", "<Space>", function()
        local l = vim.fn.line(".")
        toggle(l, l)
    end)
    map("x", "<Space>", function()
        local a, b = vim.fn.line("v"), vim.fn.line(".")
        vim.cmd("normal! \27")
        toggle(math.min(a, b), math.max(a, b))
    end)
    map("n", "a", toggle_all)
    map("n", "p", function()
        local r = rows[vim.fn.line(".")]
        if not (r and r.entry) then return end
        close_context()
        local all = lines_of(r.file.path)
        local lnum = r.entry.it.lnum
        local from, to = math.max(1, lnum - 4), math.min(#all, lnum + 4)
        local cbuf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(cbuf, 0, -1, false, vim.list_slice(all, from, to))
        vim.bo[cbuf].filetype = "kotlin"
        vim.api.nvim_buf_set_extmark(cbuf, M.ns, lnum - from, 0, { line_hl_group = "CursorLine" })
        local width = math.min(vim.o.columns - 4, 100)
        ctx_win = vim.api.nvim_open_win(cbuf, false, {
            relative = "cursor", row = 1, col = 0, width = width, height = to - from + 1,
            style = "minimal", border = "rounded",
            title = (" %s:%d "):format(r.file.rel, lnum),
        })
        vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, { buffer = buf, once = true, callback = close_context })
    end)
    map("n", "<CR>", function()
        local selected = {}
        for _, f in ipairs(files) do
            for _, e in ipairs(f.items) do
                if e.sel then selected[#selected + 1] = e.it end
            end
        end
        close_context()
        close()
        if #selected == 0 then
            vim.notify("kotlin-lite: nothing selected, nothing renamed", vim.log.levels.INFO)
            return
        end
        o.on_apply(selected)
    end)
    for _, lhs in ipairs({ "q", "<Esc>" }) do
        map("n", lhs, function()
            close_context()
            close()
        end)
    end

    render()
    vim.api.nvim_win_set_height(win, math.max(8, math.min(vim.api.nvim_buf_line_count(buf), math.floor(vim.o.lines / 2))))
    -- the first entry
    for l = 1, vim.api.nvim_buf_line_count(buf) do
        if rows[l] and rows[l].entry then
            vim.api.nvim_win_set_cursor(win, { l, 0 })
            break
        end
    end
    return buf
end

return M
