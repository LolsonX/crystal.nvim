# crystal.nvim

Crystal language support for Neovim.

## Features

- **Linting**: Ameba via [nvim-lint](https://github.com/mfussenegger/nvim-lint)
- **Formatting**: `crystal tool format` via [conform.nvim](https://github.com/stevearc/conform.nvim)
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
return {
  "mfussenegger/nvim-lint",
  optional = true,
  dependencies = { "LolsonX/crystal.nvim" },
  opts = function(_, opts)
    local lint = require("lint")
    lint.linters.ameba = require("crystal-nvim.linters.ameba")
    opts.linters_by_ft = opts.linters_by_ft or {}
    opts.linters_by_ft.crystal = { "ameba" }
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
  ft = "crystal",
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
```

## Dependencies

| Plugin | Purpose |
|---|---|
| [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) | Crystal parser installation |
| [nvim-treesitter-endwise](https://github.com/RRethy/nvim-treesitter-endwise) | Auto-close `end` blocks |
| [nvim-lint](https://github.com/mfussenegger/nvim-lint) | Ameba linter integration |
| [conform.nvim](https://github.com/stevearc/conform.nvim) | `crystal tool format` formatter |


## Structure

```
crystal.nvim/
├── lua/crystal-nvim/
│   └── init.lua        -- Plugin specs (lint, conform, treesitter, endwise)
└── queries/crystal/
    └── endwise.scm     -- Endwise queries for Crystal syntax
```
