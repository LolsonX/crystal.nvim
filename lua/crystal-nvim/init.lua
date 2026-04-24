return {
  {
    "mfussenegger/nvim-lint",
    optional = true,
    opts = {
      linters_by_ft = {
        crystal = { "ameba" },
      },
    },
  },
  {
    "mfussenegger/nvim-lint",
    optional = true,
    config = function()
      local bufname = vim.api.nvim_buf_get_name(0)
      local dir = bufname ~= "" and vim.fn.fnamemodify(bufname, ":p:h") or vim.fn.getcwd()
      local local_ameba = vim.fs.joinpath(dir, "bin", "ameba")
      local ameba_bin = (vim.fn.filereadable(local_ameba) == 1) and local_ameba or "ameba"
      if vim.fn.executable(ameba_bin) == 0 then
        vim.notify_once("ameba not found. Crystal linting disabled. Install: https://github.com/crystal-ameba/ameba", vim.log.levels.WARN)
        return
      end
      local lint = require("lint")
      lint.linters.ameba = require("crystal-nvim.linters.ameba")
    end,
  },
  {
    "stevearc/conform.nvim",
    optional = true,
    opts = {
      formatters_by_ft = {
        crystal = { "crystal" },
      },
    },
  },
  {
    "RRethy/nvim-treesitter-endwise",
    optional = true,
    dependencies = "nvim-treesitter/nvim-treesitter",
  },
  {
    "nvim-treesitter/nvim-treesitter",
    optional = true,
    opts = {
      ensure_installed = { "crystal" },
    },
  },
  {
    "nvim-treesitter/nvim-treesitter",
    optional = true,
    opts = function()
      vim.treesitter.language.register("crystal", { "cr" })
      vim.api.nvim_create_autocmd("User", {
        pattern = "TSUpdate",
        callback = function()
          local parsers = require("nvim-treesitter.parsers")
          if not parsers.crystal then
            parsers.crystal = {
              install_info = {
                url = "https://github.com/crystal-lang-tools/tree-sitter-crystal",
                queries = "queries/nvim",
              },
            }
          end
        end,
      })
    end,
  },
}
