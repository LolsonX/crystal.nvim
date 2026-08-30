local M = {}

local parser_config = {
  install_info = {
    url = "https://github.com/crystal-lang-tools/tree-sitter-crystal",
    queries = "queries/nvim",
  },
}

local function register_parser()
  local ok, parsers = pcall(require, "nvim-treesitter.parsers")
  if not ok then
    vim.notify_once(
      "crystal.nvim: Tree-sitter parser installation requires nvim-treesitter",
      vim.log.levels.WARN
    )
    return
  end

  local parser_configs = parsers.get_parser_configs and parsers.get_parser_configs() or parsers
  parser_configs.crystal = parser_configs.crystal or parser_config
end

function M.setup()
  vim.treesitter.language.register("crystal", { "cr" })

  local group = vim.api.nvim_create_augroup("CrystalNvimTreesitter", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "TSUpdate",
    callback = register_parser,
  })
end

return M
