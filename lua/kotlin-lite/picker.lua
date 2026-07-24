-- Case-insensitive list picker. Uses snacks.nvim (matcher forced to ignorecase)
-- when available, otherwise falls back to vim.ui.select. snacks stays optional:
-- it is only required lazily and behind a pcall.

local M = {}

local function snacks()
    if not require("kotlin-lite.config").options.snacks_integration then return nil end
    local ok, Snacks = pcall(require, "snacks")
    if ok and Snacks and Snacks.picker then return Snacks end
    return nil
end

--- @param items table[]  each: { text=match/label, display=?, data=?, file=?, lnum=?, col=?, pos=? }
--- @param opts table      { prompt = string }
--- @param on_choice fun(data:any)
function M.select(items, opts, on_choice)
    local Snacks = snacks()
    if Snacks then
        local pick_opts = {
            title = opts.prompt,
            items = items,
            format = function(item) return { { item.display or item.text } } end,
            matcher = { smartcase = false, ignorecase = true },
            confirm = function(picker, item)
                picker:close()
                if item then on_choice(item.data) end
            end,
        }
        -- items without a `file` can't be previewed -> disable the preview pane
        if not (items[1] and items[1].file) then pick_opts.preview = false end
        if pcall(Snacks.picker.pick, pick_opts) then return end
    end

    vim.ui.select(items, {
        prompt = opts.prompt,
        format_item = function(it) return it.display or it.text end,
    }, function(choice)
        if choice then on_choice(choice.data) end
    end)
end

return M
