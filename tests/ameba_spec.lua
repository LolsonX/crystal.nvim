local test_file = debug.getinfo(1, "S").source:sub(2)
local test_dir = vim.fn.fnamemodify(test_file, ":h")
local plugin_root = vim.fn.fnamemodify(test_dir, ":h")

package.path = table.concat({
  plugin_root .. "/lua/?.lua",
  plugin_root .. "/lua/?/init.lua",
  package.path,
}, ";")

describe("Ameba command selection", function()
  local buffer
  local project_dir

  before_each(function()
    project_dir = vim.fn.tempname()
    buffer = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buffer)
    vim.api.nvim_buf_set_name(buffer, project_dir .. "/example.cr")
  end)

  after_each(function()
    vim.api.nvim_buf_delete(buffer, { force = true })
    vim.fn.delete(project_dir, "rf")
  end)

  it("uses a project-local bin/ameba", function()
    local local_ameba = project_dir .. "/bin/ameba"
    vim.fn.mkdir(project_dir .. "/bin", "p")
    vim.fn.writefile({}, local_ameba)

    local ameba = require("crystal-nvim.linters.ameba")
    assert.equals(local_ameba, ameba.cmd())
  end)

  it("falls back to Ameba from PATH", function()
    local ameba = require("crystal-nvim.linters.ameba")
    assert.equals("ameba", ameba.cmd())
  end)
end)
