-- Startup bootstrap. Attaches lazily (keymaps only on kotlin buffers).

if vim.g.loaded_kotlin_lite then
    return
end
vim.g.loaded_kotlin_lite = true

require("kotlin-lite").init()
