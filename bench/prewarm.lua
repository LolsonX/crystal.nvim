local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
package.path = table.concat({ plugin_root .. "/lua/?.lua", plugin_root .. "/lua/?/init.lua", package.path }, ";")

local root = assert(vim.env.CRYSTAL_NVIM_BENCH_ROOT, "set CRYSTAL_NVIM_BENCH_ROOT")
local iterations = tonumber(vim.env.CRYSTAL_NVIM_BENCH_ITERATIONS) or 20
local definitions = require("crystal-nvim.definitions")

local function elapsed(start)
  return (vim.uv.hrtime() - start) / 1e6
end

local files = vim.fn.globpath(root, "src/**/*.cr", false, true)
assert(#files > 0, "project has no Crystal files")

local buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buffer, files[1])
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.fn.readfile(files[1]))
vim.api.nvim_set_current_buf(buffer)
vim.bo[buffer].filetype = "crystal"
vim.api.nvim_win_set_cursor(0, { 1, 0 })
definitions.clear_cache()
local start = vim.uv.hrtime()
definitions.prewarm(buffer)
local cold = elapsed(start)
definitions.find(buffer)

start = vim.uv.hrtime()
for iteration = 1, iterations do
  vim.api.nvim_buf_set_name(buffer, files[(iteration - 1) % #files + 1])
  definitions.prewarm(buffer)
end
local total = elapsed(start)

print(string.format("cold prewarm %.2fms; %d warmed prewarms across %d files: %.2fms total, %.2fms each", cold, iterations, #files, total, total / iterations))
vim.api.nvim_buf_delete(buffer, { force = true })
vim.cmd.qa()
