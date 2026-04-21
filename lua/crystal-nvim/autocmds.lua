local M = {}

function M.setup()
  vim.api.nvim_create_autocmd("User", {
    pattern = "TSUpdate",
    callback = function()
      require("nvim-treesitter.parsers").crystal = {
        install_info = {
          url = "https://github.com/crystal-lang-tools/tree-sitter-crystal",
          generate = false,
          generate_from_json = false,
          queries = "queries/nvim",
        },
      }
    end,
  })

  vim.treesitter.language.register("crystal", { "cr" })
end

return M
