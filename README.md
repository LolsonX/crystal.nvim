# crystal.nvim

Crystal language support for Neovim, built for [LazyVim](https://www.lazyvim.org).

## Features

- **Linting**: Ameba via [nvim-lint](https://github.com/mfussenegger/nvim-lint)
- **Formatting**: `crystal fmt` via [conform.nvim](https://github.com/stevearc/conform.nvim)
- **Treesitter**: Crystal parser from [crystal-lang-tools/tree-sitter-crystal](https://github.com/crystal-lang-tools/tree-sitter-crystal)
- **Endwise**: Auto-insert `end` keywords via [nvim-treesitter-endwise](https://github.com/RRethy/nvim-treesitter-endwise) with Crystal-specific queries
- **Filetypes**: `crystal` and `.cr` files

## Installation

### LazyVim

```lua
-- lua/plugins/crystal.lua
return { "LolsonX/crystal.nvim" }
```

### Lazy (standalone)

```lua
{
  "LolsonX/crystal.nvim",
  dependencies = {
    "LazyVim/LazyVim",
    "nvim-treesitter/nvim-treesitter",
    "RRethy/nvim-treesitter-endwise",
    "mfussenegger/nvim-lint",
    "stevearc/conform.nvim",
  },
  config = function()
    require("crystal-nvim.autocmds").setup()
  end,
}
```

## Dependencies

| Plugin | Purpose |
|---|---|
| [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) | Crystal parser installation |
| [nvim-treesitter-endwise](https://github.com/RRethy/nvim-treesitter-endwise) | Auto-close `end` blocks |
| [nvim-lint](https://github.com/mfussenegger/nvim-lint) | Ameba linter integration |
| [conform.nvim](https://github.com/stevearc/conform.nvim) | `crystal fmt` formatter |


## Structure

```
crystal.nvim/
├── lua/crystal-nvim/
│   ├── init.lua        -- LazyVim plugin specs (lint, conform, treesitter, endwise)
│   └── autocmds.lua    -- Treesitter parser override + .cr filetype registration
└── queries/crystal/
    └── endwise.scm     -- Endwise queries for Crystal syntax
```
