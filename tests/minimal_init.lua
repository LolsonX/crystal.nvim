vim.cmd([[set runtimepath=$VIMRUNTIME]])

vim.opt.runtimepath:prepend(vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"))
vim.opt.runtimepath:prepend(vim.fn.expand("~/.local/share/nvim/site"))
