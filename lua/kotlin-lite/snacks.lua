-- Optional snacks.nvim explorer integration: IntelliJ-style "Compact Middle
-- Packages" + Kotlin-aware explorer actions.
--
-- snacks.nvim is a strictly optional dependency: nothing here requires it at
-- load time. `snacks.explorer.tree` is only pulled in (via pcall) when a feature
-- actually runs, so the plugin loads fine without snacks installed.

local M = {}

local function cfg()
    return require("kotlin-lite.config").options
end

-- dirs that may START a compacted package chain. Source roots like
-- src/main/kotlin stay untouched; only real package roots get compacted,
-- matching IntelliJ's "Compact Middle Packages".
local PACKAGE_ROOTS = {
    com = true,
    org = true,
}

-- per-picker collapsed-chain state; weak keys so a gc'd picker drops its entry
local collapsed = setmetatable({}, { __mode = "k" })
local compact_enabled = true

-- Platform command to put `files` on the system clipboard as file references.
-- Returns { cmd = string[], stdin = string? } or nil when no tool is available.
--   macOS   : osascript sets real POSIX file objects
--   Windows : powershell Set-Clipboard -Path (real file objects)
--   Linux   : text/uri-list via wl-copy / xclip / xsel
local function clipboard_file_command(files)
    if vim.fn.has("mac") == 1 then
        local parts = {}
        for _, f in ipairs(files) do
            parts[#parts + 1] = 'POSIX file "' .. f .. '"'
        end
        local list = #parts == 1 and parts[1] or ("{" .. table.concat(parts, ", ") .. "}")
        return { cmd = { "osascript", "-e", "set the clipboard to " .. list } }
    elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
        local quoted = {}
        for _, f in ipairs(files) do
            quoted[#quoted + 1] = "'" .. f:gsub("'", "''") .. "'"
        end
        return {
            cmd = {
                "powershell", "-NoProfile", "-NonInteractive", "-Command",
                "Set-Clipboard -Path @(" .. table.concat(quoted, ",") .. ")",
            },
        }
    end

    local uris = {}
    for _, f in ipairs(files) do
        uris[#uris + 1] = "file://" .. f
    end
    local stdin = table.concat(uris, "\n") .. "\n"
    if vim.env.WAYLAND_DISPLAY and vim.fn.executable("wl-copy") == 1 then
        return { cmd = { "wl-copy", "--type", "text/uri-list" }, stdin = stdin }
    elseif vim.env.DISPLAY and vim.fn.executable("xclip") == 1 then
        return { cmd = { "xclip", "-selection", "clipboard", "-t", "text/uri-list" }, stdin = stdin }
    elseif vim.env.DISPLAY and vim.fn.executable("xsel") == 1 then
        return { cmd = { "xsel", "--clipboard", "--input" }, stdin = stdin }
    end
    return nil
end
M._clipboard_file_command = clipboard_file_command

-- package name for a dir, joining everything from the com/org segment onward
local function package_from_dir(dir)
    local parts = vim.split(dir, "/", { plain = true })
    local start_idx = nil
    for i, part in ipairs(parts) do
        if PACKAGE_ROOTS[part] then
            start_idx = i
            break
        end
    end
    if not start_idx then
        return nil
    end
    return table.concat(parts, ".", start_idx, #parts)
end

-- Walk down single-child directory chains; return the deepest node + the names
-- walked. Loads snacks.explorer.tree lazily so this file never eager-requires it.
local function chain(path)
    local ok, Tree = pcall(require, "snacks.explorer.tree")
    if not ok then
        return nil, {}
    end

    local node = Tree:node(path)
    local names = {}

    while node and node.dir do
        if not node.expanded then
            -- Tree:expand() is a plain fs_scandir; it asserts on non-dirs / dead paths
            if not pcall(Tree.expand, Tree, node) then
                break
            end
        end

        local count, only = 0, nil
        for _, child in pairs(node.children) do
            count, only = count + 1, child
            if count > 1 then
                break
            end
        end

        if count ~= 1 or not only or not only.dir then
            break
        end

        node = only
        names[#names + 1] = only.name
    end

    return node, names
end

-------------------------------------------------------------------
-- explorer source opts (merge into snacks' picker.sources.explorer)
-------------------------------------------------------------------

-- Returns the snacks `sources.explorer` opts implementing the Kotlin-aware
-- explorer. Empty when the integration is disabled. Callbacks require snacks
-- lazily, so this is safe to build even if snacks is never loaded.
function M.explorer_opts()
    if not cfg().snacks_integration then
        return {}
    end

    return {
        actions = {
            toggle_recursive = function(picker, item)
                local Tree = require("snacks.explorer.tree")
                local Actions = require("snacks.explorer.actions")

                local function get_children(node)
                    local children = {}
                    for _, child in pairs(node.children or {}) do
                        table.insert(children, child)
                    end
                    return children
                end

                local function collapse_recursive(node)
                    if not node.dir then return end
                    for _, child in ipairs(get_children(node)) do
                        collapse_recursive(child)
                    end
                    if node.open then
                        Tree:toggle(node.path)
                    end
                end

                local node = Tree:node(item.file)
                if not node then return end
                if not node.dir then
                    picker:action("confirm")
                    return
                end

                if node.open then
                    collapse_recursive(node)
                    Actions.update(picker, { refresh = true })
                else
                    picker:action("explorer_open_recursive")
                end
            end,

            explorer_open_one = function(picker, item)
                local Tree = require("snacks.explorer.tree")
                local Actions = require("snacks.explorer.actions")

                local node = Tree:node(item.file)
                if not node then return end
                if not node.dir then
                    picker:action("confirm")
                    return
                end

                if not node.open then
                    Tree:toggle(node.path)
                    Actions.update(picker, { refresh = true })
                end
            end,

            -- zO: open recursively, always expands, never collapses
            explorer_open_recursive = function(picker, item)
                local Tree = require("snacks.explorer.tree")
                local Actions = require("snacks.explorer.actions")
                local uv = vim.uv or vim.loop

                local function scan_dirs_sync(path, acc)
                    acc = acc or {}
                    local fd = uv.fs_scandir(path)
                    if not fd then return acc end
                    while true do
                        local name, type = uv.fs_scandir_next(fd)
                        if not name then break end
                        if type == "directory" then
                            local child_path = path .. "/" .. name
                            table.insert(acc, child_path)
                            scan_dirs_sync(child_path, acc)
                        end
                    end
                    return acc
                end

                local node = Tree:node(item.file)
                if not node then return end
                if not node.dir then
                    picker:action("confirm")
                    return
                end

                local all_dirs = scan_dirs_sync(node.path)
                Tree:open(node.path)
                for _, dir_path in ipairs(all_dirs) do
                    Tree:open(dir_path)
                end
                Actions.update(picker, { refresh = true })
            end,

            -- zR: open every directory in the whole tree, from root down
            explorer_open_all = function(picker)
                local Tree = require("snacks.explorer.tree")
                local Actions = require("snacks.explorer.actions")
                local uv = vim.uv or vim.loop

                local function scan_dirs_sync(path, acc)
                    acc = acc or {}
                    local fd = uv.fs_scandir(path)
                    if not fd then return acc end
                    while true do
                        local name, type = uv.fs_scandir_next(fd)
                        if not name then break end
                        if type == "directory" then
                            local child_path = path .. "/" .. name
                            table.insert(acc, child_path)
                            scan_dirs_sync(child_path, acc)
                        end
                    end
                    return acc
                end

                local root = picker:cwd()
                local all_dirs = scan_dirs_sync(root)
                for _, dir_path in ipairs(all_dirs) do
                    Tree:open(dir_path)
                end
                Actions.update(picker, { refresh = true })
            end,

            git_stage = function(picker, item)
                if not item then return end

                local selected = picker:selected({ fallback = true })
                local paths = {}
                for _, it in ipairs(selected) do
                    table.insert(paths, it.file)
                end

                vim.system(
                    vim.list_extend({ "git", "add", "--" }, paths),
                    { cwd = vim.fn.fnamemodify(item.file, ":h") },
                    function(res)
                        vim.schedule(function()
                            if res.code ~= 0 then
                                vim.notify("git add failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
                                return
                            end
                            local count = #paths
                            vim.notify(
                                count == 1
                                and ("Staged: " .. vim.fn.fnamemodify(paths[1], ":t"))
                                or ("Staged " .. count .. " files"),
                                vim.log.levels.INFO
                            )
                            require("snacks.explorer.actions").update(picker, { refresh = true })
                        end)
                    end
                )
            end,

            explorer_yank_file = function(picker, item)
                if not item then return end

                local selected = picker:selected({ fallback = true })
                local files = {}
                for _, it in ipairs(selected) do
                    table.insert(files, it.file)
                end

                local spec = clipboard_file_command(files)
                if not spec then
                    vim.notify("No clipboard tool found for this platform", vim.log.levels.ERROR)
                    return
                end

                local res = vim.system(spec.cmd, {
                    stdin = spec.stdin,
                    stdout = false,
                    stderr = false,
                }):wait()

                if res.code ~= 0 then
                    vim.notify("Failed to copy file(s) to system clipboard", vim.log.levels.ERROR)
                    return
                end

                local msg = #files == 1
                    and ("Copied to clipboard: " .. vim.fn.fnamemodify(files[1], ":t"))
                    or ("Copied " .. #files .. " files to clipboard")
                vim.notify(msg, vim.log.levels.INFO)
            end,

            -- Kotlin-aware rename; unavailable when several items are selected.
            explorer_kotlin_rename = function(picker, item)
                local selected = picker:selected({ fallback = true })
                if #selected > 1 then
                    vim.notify("kotlin-lite: rename is not available for multiple selection",
                        vim.log.levels.WARN)
                    return
                end
                local target = selected[1] or item
                if not target then return end
                require("kotlin-lite.actions").rename_path(target.file, function()
                    require("snacks.explorer.actions").update(picker, { refresh = true })
                end)
            end,

            explorer_toggle_compact = function(picker)
                compact_enabled = not compact_enabled
                require("snacks.explorer.actions").update(picker, { refresh = true })
                vim.notify(
                    "Compact middle packages: " .. (compact_enabled and "on" or "off"),
                    vim.log.levels.INFO
                )
            end,

            explorer_add_at_item = function(picker, item)
                local Tree = require("snacks.explorer.tree")

                local node = item and Tree:node(item.file)
                local base_dir
                if node and node.dir then
                    base_dir = node.path
                elseif item then
                    base_dir = vim.fn.fnamemodify(item.file, ":h")
                else
                    base_dir = picker:cwd()
                end

                Snacks.input({
                    prompt = "Add new file or directory (directories end with /)",
                    default = "",
                }, function(name)
                    if not name or name:find("^%s*$") then
                        return
                    end

                    local is_dir = name:sub(-1) == "/"
                    local target = base_dir .. "/" .. name

                    if is_dir then
                        vim.fn.mkdir(target, "p")
                    else
                        local parent = vim.fn.fnamemodify(target, ":h")
                        vim.fn.mkdir(parent, "p")

                        if vim.fn.filereadable(target) == 0 then
                            local lines = {}

                            -- new .kt file: seed package + class from the target dir
                            if target:sub(-3) == ".kt" then
                                local class_name = vim.fn.fnamemodify(target, ":t:r")
                                local pkg = package_from_dir(parent)

                                if pkg then
                                    table.insert(lines, "package " .. pkg)
                                    table.insert(lines, "")
                                end
                                table.insert(lines, "class " .. class_name .. " {")
                                table.insert(lines, "")
                                table.insert(lines, "}")
                                table.insert(lines, "")
                            end

                            vim.fn.writefile(lines, target)
                        end
                    end

                    Tree:open(base_dir)
                    require("snacks.explorer.actions").update(picker, { refresh = true })
                end)
            end,
        },
        win = {
            list = {
                keys = {
                    ["a"] = { "explorer_add_at_item", desc = "Add file/dir (Kotlin-aware, compact-aware)" },
                    ["Y"] = { "explorer_yank_file", desc = "Copy file(s) to system clipboard" },
                    ["<leader>cR"] = { "explorer_kotlin_rename", desc = "Rename file (Kotlin-aware)" },
                    ["zo"] = { "explorer_open_one", desc = "Open directory (one level)" },
                    ["zO"] = { "explorer_open_recursive", desc = "Open directory recursively" },
                    ["za"] = { "confirm", desc = "Toggle directory" },
                    ["zA"] = { "toggle_recursive", desc = "Toggle directory recursively" },
                    ["zM"] = { "explorer_close_all", desc = "Close all directories" },
                    ["zR"] = { "explorer_open_all", desc = "Open all directories" },
                    ["<A-CR>"] = { "toggle_recursive", desc = "Toggle recursive expand/collapse" },
                    ["<leader>ga"] = { "git_stage", desc = "Git: Add to index" },
                    ["<A-a>"] = { "git_stage", desc = "Git: Add to index" },
                    ["<leader>km"] = { "explorer_toggle_compact", desc = "Toggle compact middle packages" },
                },
            },
        },

        ---@param item snacks.picker.explorer.Item
        transform = function(item, ctx)
            local opts = ctx.picker.opts ---@diagnostic disable-line
            if not compact_enabled or opts.tree == false or ctx.filter.meta.searching then
                return -- feature off / flat list / search results: leave everything alone
            end

            -- cwd node is emitted first -> new find pass
            if item.file == ctx:cwd() then
                collapsed[ctx.picker] = {}
                return
            end

            local state = collapsed[ctx.picker]
            if not state then
                return
            end

            -- re-attach children of a collapsed chain to its head so connectors/indent stay right
            local head = item.parent and state[item.parent.file]
            if head then
                item.parent = head
            end

            -- middle link -> drop from the list
            if state[item.file] then
                return false
            end

            if not item.dir then
                return
            end

            if not PACKAGE_ROOTS[vim.fs.basename(item.file)] then
                return
            end

            local deepest, names = chain(item.file)
            if not deepest or #names == 0 then
                return
            end

            local path = item.file
            for _, name in ipairs(names) do
                path = path .. "/" .. name
                state[path] = item
            end

            -- render dotted label + re-target the item at the deepest dir, so
            -- confirm / close / add / rename act on the compacted leaf
            item._flat = vim.fs.basename(item.file) .. "." .. table.concat(names, ".")
            item.file = deepest.path
            item.text = deepest.path
            item.open = deepest.open
        end,

        ---@param item snacks.picker.explorer.Item
        format = function(item, picker)
            if not item._flat then
                return Snacks.picker.format.file(item, picker)
            end
            -- tree mode renders basename only -> swap it for the dotted name
            local file = item.file
            item.file = vim.fs.dirname(file) .. "/" .. item._flat
            local ret = Snacks.picker.format.file(item, picker)
            item.file = file
            return ret
        end,
    }
end

-------------------------------------------------------------------
-- triggered entry (<leader>ke): reveal in the explorer
-------------------------------------------------------------------
function M.reveal()
    if not cfg().snacks_integration then
        return
    end

    local ok, tree = pcall(require, "snacks.explorer.tree")
    if not ok then
        vim.notify(
            "kotlin-lite: 'snacks.nvim' is required for this feature, but it is not installed.",
            vim.log.levels.WARN
        )
        return
    end

    -- expand the current file's directory chain, then reveal it
    local dir = vim.fn.expand("%:p:h")
    if dir ~= "" then
        pcall(function() tree:open(dir) end)
    end

    local Snacks = rawget(_G, "Snacks")
    if not (Snacks and Snacks.explorer) then
        return
    end
    local picker = Snacks.explorer.reveal and Snacks.explorer.reveal() or Snacks.explorer()
    if picker then
        pcall(function() picker:focus() end)
    end
end

-------------------------------------------------------------------
-- toggle compact middle packages from anywhere (<leader>km)
-------------------------------------------------------------------
function M.toggle_compact()
    if not cfg().snacks_integration then return end
    compact_enabled = not compact_enabled

    -- refresh any open explorer so the change shows immediately
    local ok, Snacks = pcall(require, "snacks")
    if ok and Snacks.picker and Snacks.picker.get then
        local got, pickers = pcall(Snacks.picker.get, { source = "explorer" })
        if got and pickers then
            for _, p in ipairs(pickers) do
                pcall(function() require("snacks.explorer.actions").update(p, { refresh = true }) end)
            end
        end
    end
    vim.notify("Compact middle packages: " .. (compact_enabled and "on" or "off"), vim.log.levels.INFO)
end

return M
