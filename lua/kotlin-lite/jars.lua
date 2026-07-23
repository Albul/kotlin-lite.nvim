-- *-sources.jar discovery/extraction. Extracted trees feed project search and
-- are opened read-only.

local M = {}

-- extracted source trees, refreshed by scan_cache()
local jar_dirs = {}

local function cfg()
    return require("kotlin-lite.config").options
end

function M.jar_dirs()
    return jar_dirs
end

function M.jar_label(dir)
    local ok, lines = pcall(vim.fn.readfile, dir .. "/.jarname")
    if ok and lines[1] then return lines[1] end
    return vim.fn.fnamemodify(dir, ":t")
end

function M.scan_cache()
    local cache_dir = cfg().cache_dir
    jar_dirs = {}
    if vim.fn.isdirectory(cache_dir) == 0 then return end
    for name, t in vim.fs.dir(cache_dir) do
        if t == "directory" then
            local dir = cache_dir .. "/" .. name
            if vim.fn.filereadable(dir .. "/.extracted") == 1 then
                table.insert(jar_dirs, dir)
            end
        end
    end
end

function M.is_jar(file)
    return file:find(cfg().cache_dir, 1, true) == 1
end

function M.extract_jar(jar_path)
    local dir = cfg().cache_dir .. "/" .. vim.fn.sha256(jar_path)
    if vim.fn.filereadable(dir .. "/.extracted") == 1 then
        vim.notify("kotlin-lite: already extracted", vim.log.levels.INFO)
        return
    end
    vim.fn.mkdir(dir, "p")
    local jar_name = vim.fn.fnamemodify(jar_path, ":t")
    vim.notify("kotlin-lite: extracting " .. jar_name .. " ...", vim.log.levels.INFO)
    vim.system({ "unzip", "-o", "-q", jar_path, "-d", dir }, {}, function(res)
        vim.schedule(function()
            if res.code == 0 then
                vim.fn.writefile({ jar_name }, dir .. "/.jarname")
                vim.fn.writefile({}, dir .. "/.extracted")
                M.scan_cache()
                vim.notify("kotlin-lite: " .. jar_name .. " is ready", vim.log.levels.INFO)
            else
                vim.fn.delete(dir, "rf")
                vim.notify("kotlin-lite: unzip failed for " .. jar_name, vim.log.levels.ERROR)
            end
        end)
    end)
end

function M.pick_sources_jar()
    local search_roots = {}
    for _, p in ipairs(cfg().jar_search_roots) do
        p = vim.fn.expand(p)
        if vim.fn.isdirectory(p) == 1 then table.insert(search_roots, p) end
    end
    if #search_roots == 0 then
        vim.notify("kotlin-lite: no jar search roots found", vim.log.levels.WARN)
        return
    end
    local cmd = { "find" }
    vim.list_extend(cmd, search_roots)
    vim.list_extend(cmd, { "-type", "f", "-name", "*-sources.jar" })
    vim.system(cmd, { text = true }, function(res)
        vim.schedule(function()
            local jars = vim.split(res.stdout or "", "\n", { trimempty = true })
            if #jars == 0 then
                vim.notify("kotlin-lite: no *-sources.jar found", vim.log.levels.WARN)
                return
            end
            table.sort(jars, function(a, b)
                return vim.fn.fnamemodify(a, ":t") < vim.fn.fnamemodify(b, ":t")
            end)
            local done = {}
            for _, d in ipairs(jar_dirs) do done[M.jar_label(d)] = true end
            vim.ui.select(jars, {
                prompt = "Extract sources jar:",
                format_item = function(j)
                    local n = vim.fn.fnamemodify(j, ":t")
                    return (done[n] and "[+] " or "    ") .. n
                end,
            }, function(choice)
                if choice then M.extract_jar(choice) end
            end)
        end)
    end)
end

function M.clear()
    vim.fn.delete(cfg().cache_dir, "rf")
    M.scan_cache()
    vim.notify("kotlin-lite: jar cache cleared", vim.log.levels.INFO)
end

-- mark cache files read-only + initial scan
function M.setup()
    vim.api.nvim_create_autocmd("BufReadPost", {
        group = vim.api.nvim_create_augroup("kotlin-lite-jar-ro", { clear = true }),
        pattern = cfg().cache_dir .. "/*",
        callback = function(ev)
            vim.bo[ev.buf].readonly = true
            vim.bo[ev.buf].modifiable = false
            vim.bo[ev.buf].swapfile = false
        end,
    })
    M.scan_cache()
end

return M
