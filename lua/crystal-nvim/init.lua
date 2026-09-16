local M = {}

local defaults = {
  lint = true,
  format = true,
  treesitter = true,
  definitions = true,
}

local function append_unique(items, item)
  for _, existing in ipairs(items) do
    if existing == item then
      return
    end
  end

  table.insert(items, item)
end

local function notify_missing_dependency(feature, dependency)
  vim.notify_once(
    string.format("crystal.nvim: %s is disabled because %s is not installed", feature, dependency),
    vim.log.levels.WARN
  )
end

local function configure_linting()
  local ok, lint = pcall(require, "lint")
  if not ok then
    notify_missing_dependency("linting", "nvim-lint")
    return
  end

  lint.linters.ameba = require("crystal-nvim.linters.ameba")
  lint.linters_by_ft.crystal = lint.linters_by_ft.crystal or {}
  append_unique(lint.linters_by_ft.crystal, "ameba")
end

local function configure_formatting()
  local ok, conform = pcall(require, "conform")
  if not ok then
    notify_missing_dependency("formatting", "conform.nvim")
    return
  end

  conform.formatters_by_ft = conform.formatters_by_ft or {}
  conform.formatters_by_ft.crystal = conform.formatters_by_ft.crystal or {}
  append_unique(conform.formatters_by_ft.crystal, "crystal")
end

local function validate_options(options)
  for name, value in pairs(options) do
    if defaults[name] == nil then
      error("crystal.nvim: unknown option '" .. name .. "'")
    end
    if name == "definitions" and type(value) == "table" then
      for option, enabled in pairs(value) do
        if option ~= "stdlib" and option ~= "mappings" then
          error("crystal.nvim: unknown definitions option '" .. option .. "'")
        end
        if option == "mappings" then
          if type(enabled) ~= "table" then
            error("crystal.nvim: definitions.mappings must be a table")
          end
          for mapping, lhs in pairs(enabled) do
            if mapping ~= "definition" and mapping ~= "implementation" then
              error("crystal.nvim: unknown definitions mapping '" .. mapping .. "'")
            end
            if type(lhs) ~= "string" and lhs ~= false then
              error("crystal.nvim: definitions.mappings." .. mapping .. " must be a string or false")
            end
          end
        elseif type(enabled) ~= "boolean" then
          error("crystal.nvim: definitions." .. option .. " must be a boolean")
        end
      end
    elseif type(value) ~= "boolean" then
      error("crystal.nvim: option '" .. name .. "' must be a boolean")
    end
  end
end

function M.setup(options)
  options = options or {}
  validate_options(options)
  options = vim.tbl_extend("force", defaults, options)

  if options.lint then
    configure_linting()
  end
  if options.format then
    configure_formatting()
  end
  if options.treesitter then
    require("crystal-nvim.treesitter").setup()
  end
  if options.definitions then
    require("crystal-nvim.definitions").setup(type(options.definitions) == "table" and options.definitions or nil)
  end
end

return M
