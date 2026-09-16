local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
package.path = table.concat({ plugin_root .. "/lua/?.lua", plugin_root .. "/lua/?/init.lua", package.path }, ";")

local files = tonumber(vim.env.CRYSTAL_NVIM_BENCH_FILES) or 200
local root = vim.fn.tempname()
vim.g.crystal_nvim_cache_dir = root .. "/cache"
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
  local source = {
    "module Benchmark",
    "  class Type" .. number,
    "    def render",
    "    end",
    "  end",
    "end",
  }
  if number < files then
    table.insert(source, 1, 'require "./type_' .. (number + 1) .. '"')
  end
  write(root .. "/src/type_" .. number .. ".cr", source)
end
write(root .. "/src/app.cr", { 'require "./type_1"', "Benchmark::Type" .. files .. ".new" })

local buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buffer, root .. "/src/app.cr")
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { 'require "./type_1"', "Benchmark::Type" .. files .. ".new" })
vim.bo[buffer].modified = false
vim.api.nvim_set_current_buf(buffer)
vim.api.nvim_win_set_cursor(0, { 2, 12 })

definitions.clear_cache()
local start = vim.uv.hrtime()
assert(definitions.find(buffer))
local cold = elapsed(start)
vim.wait(1000)

definitions.clear_cache()
local original_parser = vim.treesitter.get_string_parser
local parse_count = 0
vim.treesitter.get_string_parser = function(...)
  parse_count = parse_count + 1
  return original_parser(...)
end
start = vim.uv.hrtime()
assert(definitions.find(buffer))
local disk = elapsed(start)
local disk_parses = parse_count

definitions.clear_cache()
parse_count = 0
definitions.prewarm(buffer)
vim.wait(1000)
start = vim.uv.hrtime()
assert(definitions.find(buffer))
local prewarmed = elapsed(start)
local prewarmed_parses = parse_count
vim.treesitter.get_string_parser = original_parser

start = vim.uv.hrtime()
for _ = 1, 20 do
  assert(definitions.find(buffer))
end
local warm = elapsed(start) / 20

print(string.format("%d-file require graph: cold %.2fms, disk %.2fms (%d parses), prewarmed %.2fms (%d parses), warm %.2fms", files, cold, disk, disk_parses, prewarmed, prewarmed_parses, warm))
vim.api.nvim_buf_delete(buffer, { force = true })
vim.fn.delete(root, "rf")
vim.cmd.qa()
