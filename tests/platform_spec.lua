local test_file = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(vim.fn.fnamemodify(test_file, ":h"), ":h")

package.path = table.concat({
  plugin_root .. "/lua/?.lua",
  plugin_root .. "/lua/?/init.lua",
  package.path,
}, ";")

local platform = require("crystal-nvim.platform")

describe("Crystal platform targets", function()
  local cases = {
    { { sysname = "Linux", machine = "x86_64" }, "GNU libc", "x86_64-linux-gnu" },
    { { sysname = "Linux", machine = "aarch64" }, "musl libc", "aarch64-linux-musl" },
    { { sysname = "Darwin", machine = "arm64" }, "", "arm64-darwin" },
    { { sysname = "FreeBSD", machine = "amd64" }, "", "x86_64-freebsd" },
    { { sysname = "OpenBSD", machine = "amd64" }, "", "amd64-unknown-openbsd" },
    { { sysname = "Windows_NT", machine = "AMD64" }, "", "x86_64-windows-gnu" },
  }

  for _, case in ipairs(cases) do
    it("maps " .. case[1].sysname .. " " .. case[1].machine, function()
      assert.equals(case[3], platform.libc_target(case[1], case[2]))
    end)
  end
end)
