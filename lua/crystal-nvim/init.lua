return {
  {
    "mfussenegger/nvim-lint",
    opts = function(_, opts)
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
      vim.list_extend(opts.ensure_installed, { "crystal" })
    end,
  },
}
