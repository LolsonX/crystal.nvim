vim.cmd([[set runtimepath=$VIMRUNTIME]])

local deps_dir = os.getenv("DEPS_DIR") or vim.fn.expand("~/.local/share/nvim/lazy")

vim.opt.runtimepath:prepend(deps_dir .. "/plenary.nvim")
vim.opt.runtimepath:prepend(vim.fn.expand("~/.local/share/nvim/site"))
