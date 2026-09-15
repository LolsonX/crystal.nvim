local M = {}

local function check_dependency(health, module, feature)
  if pcall(require, module) then
    health.ok(module .. " available for " .. feature)
  else
    health.info(module .. " unavailable; " .. feature .. " disabled")
  end
end

function M.check()
  local health = vim.health
  health.start("crystal.nvim")

  if vim.fn.executable("crystal") == 1 then
    local version = vim.fn.systemlist({ "crystal", "--version" })[1] or "unknown version"
    if vim.v.shell_error == 0 then
      health.ok("Crystal executable: " .. version)
    else
      health.warn("Crystal executable failed: " .. version)
    end
  else
    health.warn("Crystal executable not found", { "Install Crystal to use formatting and standard-library definitions." })
  end

  if pcall(vim.treesitter.language.inspect, "crystal") then
    health.ok("Crystal Tree-sitter parser available")
  elseif pcall(require, "nvim-treesitter.parsers") then
    health.warn("Crystal Tree-sitter parser unavailable", { "Run `:TSInstall crystal`." })
  else
    health.warn("Crystal Tree-sitter parser unavailable", { "Install nvim-treesitter, then run `:TSInstall crystal`." })
  end

  check_dependency(health, "lint", "linting")
  check_dependency(health, "conform", "formatting")

  if vim.bo.filetype ~= "crystal" then
    health.info("Open a Crystal buffer to verify the `gd` mapping")
    return
  end
  if vim.fn.maparg("gd", "n", false, true).lhs == "gd" then
    health.ok("`gd` mapping available")
  else
    health.warn("`gd` mapping unavailable", { "Call `require(\"crystal-nvim\").setup()` after opening Neovim." })
  end
end

return M
