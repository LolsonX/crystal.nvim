# crystal.nvim

Crystal language support for Neovim.

## Features

- **Linting**: Ameba via [nvim-lint](https://github.com/mfussenegger/nvim-lint)
- **Formatting**: `crystal tool format` via [conform.nvim](https://github.com/stevearc/conform.nvim)
- **Treesitter**: Crystal parser from [crystal-lang-tools/tree-sitter-crystal](https://github.com/crystal-lang-tools/tree-sitter-crystal)
- **Endwise**: Auto-insert `end` keywords via [nvim-treesitter-endwise](https://github.com/RRethy/nvim-treesitter-endwise) with Crystal-specific queries
- **Filetypes**: `crystal` and `.cr` files

## Installation

### Option 1: Portable (any plugin manager)

Just add the plugin. The `plugin/crystal.lua` file runs after ALL plugins are loaded, handling all integration:

```lua
-- lua/plugins/crystal.lua
return { "LolsonX/crystal.nvim", dependencies: { "RRethy/nvim-treesitter-endwise" } }
```

Works with lazy.nvim, LazyVim, packer.vim, vim-plug, or any plugin manager.

### Option 2: lazy.nvim with full integration

The portable approach above works everywhere. No extra configuration needed.

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
├── plugin/
│   └── crystal.lua           -- Portable integration (loads after all plugins)
├── runtime/
│   └── queries/
│       └── crystal/
│           └── endwise.scm  -- Endwise queries for Crystal syntax
├── lua/
│   └── crystal-nvim/
│       └── linters/
│           └── ameba.lua   -- Ameba linter definition for nvim-lint
└── README.md
```

## Manual integration (if needed)

If you prefer to manage integrations explicitly, you can also add these configs manually:

**Linting**:
```lua
-- Add to your lint.linters_by_ft.crystal
lint.linters_by_ft.crystal = lint.linters_by_ft.crystal or {}
table.insert(lint.linters_by_ft.crystal, "ameba")
```

**Formatting**:
```lua
-- Add to your conform.formatters_by_ft.crystal
conform.formatters_by_ft.crystal = conform.formatters_by_ft.crystal or {}
table.insert(conform.formatters_by_ft.crystal, "crystal")
```

**Treesitter**:
```lua
vim.treesitter.language.register("crystal", { "cr" })
```

Queries from `runtime/queries/crystal/endwise.scm` will be automatically discovered by Neovim's query system since they're placed in the standard `runtime/queries/` directory.
