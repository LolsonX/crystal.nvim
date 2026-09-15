local test_file = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(test_file, ":h:h")

package.path = table.concat({
  plugin_root .. "/lua/?.lua",
  plugin_root .. "/lua/?/init.lua",
  package.path,
}, ";")

local health = require("crystal-nvim.health")

describe("Crystal health", function()
  local original_health
  local original_executable
  local original_systemlist
  local original_inspect
  local original_filetype
  local events

  before_each(function()
    original_health = vim.health
    original_executable = vim.fn.executable
    original_systemlist = vim.fn.systemlist
    original_inspect = vim.treesitter.language.inspect
    original_filetype = vim.bo.filetype
    events = {}
    vim.health = setmetatable({}, {
      __index = function(_, name)
        return function(message)
          table.insert(events, { name, message })
        end
      end,
    })
    vim.fn.executable = function()
      return 1
    end
    vim.fn.systemlist = function()
      return { "Crystal 1.21.0" }
    end
    vim.fn.system("true")
    vim.treesitter.language.inspect = function()
      return {}
    end
  end)

  after_each(function()
    vim.health = original_health
    vim.fn.executable = original_executable
    vim.fn.systemlist = original_systemlist
    vim.treesitter.language.inspect = original_inspect
    vim.bo.filetype = original_filetype
  end)

  it("reports a working Crystal executable and parser", function()
    health.check()

    assert.same({ "ok", "Crystal executable: Crystal 1.21.0" }, events[2])
    assert.same({ "ok", "Crystal Tree-sitter parser available" }, events[3])
  end)

  it("warns when Crystal exits with an error", function()
    vim.fn.systemlist = function()
      return { "broken Crystal" }
    end
    vim.fn.system("false")

    health.check()

    assert.same({ "warn", "Crystal executable failed: broken Crystal" }, events[2])
  end)

  it("warns when Crystal is unavailable", function()
    vim.fn.executable = function()
      return 0
    end

    health.check()

    assert.same({ "warn", "Crystal executable not found" }, events[2])
  end)

  it("reports the gd mapping in a Crystal buffer", function()
    vim.bo.filetype = "crystal"
    vim.keymap.set("n", "gd", "<cmd>echo 'definition'<cr>", { buffer = 0 })

    health.check()

    assert.same({ "ok", "`gd` mapping available" }, events[#events])
    vim.keymap.del("n", "gd", { buffer = 0 })
  end)
end)
