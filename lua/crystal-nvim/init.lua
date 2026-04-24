return {
  "LolsonX/crystal.nvim",
  dependencies = {
    "mfussenegger/nvim-lint",
    "stevearc/conform.nvim",
    "nvim-treesitter/nvim-treesitter",
    "RRethy/nvim-treesitter-endwise",
  },
  config = function()
    vim.api.nvim_create_autocmd("User", {
      pattern = "LazyConfigDone",
      once = true,
      callback = function()
        local lint = require("lint")
        lint.linters.ameba = require("crystal-nvim.linters.ameba")

        local bufname = vim.api.nvim_buf_get_name(0)
        local dir = bufname ~= "" and vim.fn.fnamemodify(bufname, ":p:h") or vim.fn.getcwd()
        local local_ameba = vim.fs.joinpath(dir, "bin", "ameba")
        local ameba_bin = (vim.fn.filereadable(local_ameba) == 1) and local_ameba or "ameba"
        if vim.fn.executable(ameba_bin) == 0 then
          vim.notify_once("ameba not found. Crystal linting disabled. Install: https://github.com/crystal-ameba/ameba", vim.log.levels.WARN)
        else
          lint.linters_by_ft = lint.linters_by_ft or {}
          lint.linters_by_ft.crystal = lint.linters_by_ft.crystal or {}
          table.insert(lint.linters_by_ft.crystal, "ameba")
        end

        local conform = require("conform")
        conform.formatters_by_ft = conform.formatters_by_ft or {}
        conform.formatters_by_ft.crystal = conform.formatters_by_ft.crystal or {}
        table.insert(conform.formatters_by_ft.crystal, "crystal")

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

        local ts_ok, ts_opts = pcall(function()
          return require("lazy.core.config").plugins["nvim-treesitter"].opts
        end)
        if ts_ok and ts_opts and ts_opts.ensure_installed then
          if not vim.tbl_contains(ts_opts.ensure_installed, "crystal") then
            table.insert(ts_opts.ensure_installed, "crystal")
          end
        end
      end,
    })
  end,
}
