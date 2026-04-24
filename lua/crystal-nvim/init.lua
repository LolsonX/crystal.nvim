return {
  {
    "mfussenegger/nvim-lint",
    opts = function(_, opts)
      if vim.fn.executable("ameba") == 0 then
        vim.notify_once("ameba not found. Crystal linting disabled. Install: https://github.com/crystal-ameba/ameba", vim.log.levels.WARN)
        return
      end
      local lint = require("lint")
      lint.linters.ameba = require("crystal-nvim.linters.ameba")
      opts.linters_by_ft = opts.linters_by_ft or {}
      opts.linters_by_ft.crystal = { "ameba" }
    end,
  },
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        crystal = { "crystal" },
      },
    },
  },
  {
    "RRethy/nvim-treesitter-endwise",
    dependencies = "nvim-treesitter/nvim-treesitter",
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.parser_config = opts.parser_config or {}
      opts.parser_config.crystal = {
        install_info = {
          url = "https://github.com/crystal-lang-tools/tree-sitter-crystal",
          generate = false,
          generate_from_json = false,
          queries = "queries/nvim",
        },
      }
      vim.list_extend(opts.ensure_installed, { "crystal" })
      vim.treesitter.language.register("crystal", { "cr" })
    end,
  },
}
