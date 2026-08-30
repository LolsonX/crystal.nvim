local test_file = debug.getinfo(1, "S").source:sub(2)
local test_dir = vim.fn.fnamemodify(test_file, ":h")
local plugin_root = vim.fn.fnamemodify(test_dir, ":h")

package.path = table.concat({
  plugin_root .. "/lua/?.lua",
  plugin_root .. "/lua/?/init.lua",
  package.path,
}, ";")

local function load_plugin(lint, conform)
  package.loaded["crystal-nvim"] = nil
  package.preload.lint = function()
    return lint
  end
  package.preload.conform = function()
    return conform
  end

  return require("crystal-nvim")
end

describe("crystal-nvim.setup", function()
  local lint
  local conform

  before_each(function()
    package.loaded.lint = nil
    package.loaded.conform = nil
    lint = {
      linters = {},
      linters_by_ft = {},
    }
    conform = {
      formatters_by_ft = {},
    }
  end)

  after_each(function()
    package.preload.lint = nil
    package.preload.conform = nil
    package.preload["nvim-treesitter.parsers"] = nil
    package.loaded["nvim-treesitter.parsers"] = nil
    package.loaded["crystal-nvim.treesitter"] = nil
  end)

  it("adds Ameba and the Crystal formatter", function()
    load_plugin(lint, conform).setup({ treesitter = false })

    assert.equals("ameba", lint.linters_by_ft.crystal[1])
    assert.equals("crystal", conform.formatters_by_ft.crystal[1])
    assert.is_not_nil(lint.linters.ameba)
  end)

  it("preserves existing Crystal integrations", function()
    lint.linters_by_ft.crystal = { "custom" }
    conform.formatters_by_ft.crystal = { "custom_formatter" }

    load_plugin(lint, conform).setup({ treesitter = false })

    assert.same({ "custom", "ameba" }, lint.linters_by_ft.crystal)
    assert.same({ "custom_formatter", "crystal" }, conform.formatters_by_ft.crystal)
  end)

  it("does not duplicate integrations when setup runs twice", function()
    local crystal = load_plugin(lint, conform)
    crystal.setup({ treesitter = false })
    crystal.setup({ treesitter = false })

    assert.same({ "ameba" }, lint.linters_by_ft.crystal)
    assert.same({ "crystal" }, conform.formatters_by_ft.crystal)
  end)

  it("respects disabled integrations", function()
    load_plugin(lint, conform).setup({
      lint = false,
      format = false,
      treesitter = false,
    })

    assert.is_nil(lint.linters_by_ft.crystal)
    assert.is_nil(conform.formatters_by_ft.crystal)
  end)

  it("registers the Tree-sitter update hook", function()
    load_plugin(lint, conform).setup({
      lint = false,
      format = false,
    })

    local autocommands = vim.api.nvim_get_autocmds({ group = "CrystalNvimTreesitter" })
    assert.equals(1, #autocommands)
    assert.equals("User", autocommands[1].event)
    assert.equals("TSUpdate", autocommands[1].pattern)
  end)

  it("adds Crystal to the legacy Tree-sitter parser registry", function()
    local parser_configs = {}
    package.preload["nvim-treesitter.parsers"] = function()
      return {
        get_parser_configs = function()
          return parser_configs
        end,
      }
    end

    load_plugin(lint, conform).setup({
      lint = false,
      format = false,
    })
    vim.api.nvim_exec_autocmds("User", { pattern = "TSUpdate" })

    assert.equals("https://github.com/crystal-lang-tools/tree-sitter-crystal", parser_configs.crystal.install_info.url)
  end)

  it("adds Crystal to the current Tree-sitter parser registry", function()
    local parser_configs = {}
    package.preload["nvim-treesitter.parsers"] = function()
      return parser_configs
    end

    load_plugin(lint, conform).setup({
      lint = false,
      format = false,
    })
    vim.api.nvim_exec_autocmds("User", { pattern = "TSUpdate" })

    assert.equals("https://github.com/crystal-lang-tools/tree-sitter-crystal", parser_configs.crystal.install_info.url)
  end)
end)
