# crystal.nvim

Crystal language support for Neovim.

## Features

- **Linting**: Ameba via [nvim-lint](https://github.com/mfussenegger/nvim-lint)
- **Formatting**: `crystal tool format` via [conform.nvim](https://github.com/stevearc/conform.nvim)
- **Treesitter**: Crystal parser from [crystal-lang-tools/tree-sitter-crystal](https://github.com/crystal-lang-tools/tree-sitter-crystal)
- **Endwise**: Auto-insert `end` keywords via [nvim-treesitter-endwise](https://github.com/RRethy/nvim-treesitter-endwise) with Crystal-specific queries
- **Definitions**: Project-local `gd` for declarations, without an LSP client
- **Filetypes**: `crystal` and `.cr` files

## Installation

### Setup

Call `setup()` from your plugin manager configuration. crystal.nvim does nothing until you call it.

```lua
-- lua/plugins/crystal.lua
return {
  "LolsonX/crystal.nvim",
  dependencies = {
    "mfussenegger/nvim-lint",
    "stevearc/conform.nvim",
    "nvim-treesitter/nvim-treesitter",
    "RRethy/nvim-treesitter-endwise",
  },
  config = function()
    require("crystal-nvim").setup()
  end,
}
```

Disable integrations you do not use:

```lua
require("crystal-nvim").setup({
  lint = false,
  format = false,
  treesitter = true,
  definitions = true,
})
```

Standard-library navigation is enabled by default. Disable it when needed:

```lua
require("crystal-nvim").setup({
  definitions = { stdlib = false },
})
```

Configure or disable buffer-local navigation mappings:

```lua
require("crystal-nvim").setup({
  definitions = {
    mappings = {
      definition = "gd",
      implementation = "gD", -- Set false to disable.
    },
  },
})
```

Run `:checkhealth crystal-nvim` to verify Crystal, the Tree-sitter parser, optional integrations, and `gd` in an open Crystal buffer.

Benchmark cold and cached definitions lookups with:

```bash
nvim --headless -u tests/minimal_init.lua -l bench/definitions.lua
```

### Definitions

`gd` finds Crystal declarations under the nearest `shard.yml` (falling back to `.git`), including shards installed in the project's `lib/` directory. It indexes classes, modules, structs, enums, libs, unions, annotations, constants, methods, macros, and `fun` declarations. Local variables and method arguments resolve to their nearest declaration. Instance methods resolve when their receiver was directly created with `Type.new`; ambiguous names and receivers that need further type inference do not jump.

The index reads project source and unsaved open buffers. Crystal buffers prewarm their project index on open. Cold project indexing runs in background batches, while `gd` completes any unfinished index before navigating. Project indexes, standard-library source maps, and parsed standard-library definition files persist under Neovim's cache directory. Project indexes return immediately on hydration, then validate source signatures after a short idle delay. Relative, `src/`, and recursive declared-shard `require` chains limit candidates to reachable files; their resolved graph stays cached until the source changes. Files without a resolvable project require retain whole-project lookup. Generic, nilable, and union type declarations resolve receiver methods. Large changed projects show indexing start and completion notifications. Modified buffers always overlay cached disk source. Run `:CrystalDefinitionsClearCache` to clear persisted and in-memory definition caches. `gd` lists matching project definitions first, followed by matching declarations from the installed Crystal standard library. Ambiguous method entries show compact visibility labels: `pub`, `pro`, or `pri`. `gD` finds an unqualified method implementation from its enclosing class, superclass, included module, or extended module. Set `definitions.stdlib = false` to exclude standard-library results. It does not start an LSP client, compile the project, edit source text, or write project files.

### Navigation demo

[`demo/navigation`](demo/navigation) is a self-contained Crystal project for manually testing current `gd` behavior and documented future navigation cases.

The plugin registers integrations only. Configure nvim-lint to run linting and Conform to format on your preferred events or mappings.

After setup, update nvim-treesitter and install the Crystal parser:

```vim
:TSUpdate
:TSInstall crystal
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
├── lua/
│   └── crystal-nvim/
│       ├── init.lua         -- Public setup interface
│       ├── treesitter.lua  -- Tree-sitter integration
│       └── linters/
│           └── ameba.lua   -- Ameba linter definition for nvim-lint
├── queries/
│   └── crystal/
│       └── endwise.scm     -- Endwise queries for Crystal syntax
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

Queries from `queries/crystal/endwise.scm` are automatically discovered through Neovim's runtimepath.
