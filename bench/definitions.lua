local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
package.path = table.concat({ plugin_root .. "/lua/?.lua", plugin_root .. "/lua/?/init.lua", package.path }, ";")

local files = tonumber(vim.env.CRYSTAL_NVIM_BENCH_FILES) or 200
local root = vim.fn.tempname()
local definitions = require("crystal-nvim.definitions")

local function write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

local function elapsed(start)
  return (vim.uv.hrtime() - start) / 1e6
end

write(root .. "/shard.yml", { "name: definitions-benchmark" })
for number = 1, files do
  write(root .. "/src/type_" .. number .. ".cr", {
    "module Benchmark",
    "  class Type" .. number,
    "    def render",
    "    end",
    "  end",
    "end",
  })
end

local buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buffer, root .. "/src/app.cr")
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "Benchmark::Type" .. files .. ".new" })
vim.api.nvim_set_current_buf(buffer)
vim.api.nvim_win_set_cursor(0, { 1, 12 })

definitions.clear_cache()
local start = vim.uv.hrtime()
assert(definitions.find(buffer))
local cold = elapsed(start)

start = vim.uv.hrtime()
for _ = 1, 20 do
  assert(definitions.find(buffer))
end
local warm = elapsed(start) / 20

print(string.format("%d files: cold %.2fms, warm %.2fms", files, cold, warm))
vim.api.nvim_buf_delete(buffer, { force = true })
vim.fn.delete(root, "rf")
vim.cmd.qa()
