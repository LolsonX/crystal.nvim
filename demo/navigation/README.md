# Crystal Navigation Demo

Manual fixture for Crystal navigation features. Open this directory in Neovim, call `require("crystal-nvim").setup()`, then place the cursor on marked identifiers and press `gd`.

`src/usage.cr` exercises definitions currently supported by crystal.nvim. Each target has one unambiguous declaration in `src/declarations.cr`.

`src/ambiguous.cr` intentionally has two `Widget` declarations. A bare `Widget` outside a namespace opens the selection UI; a qualified name does not.

`src/locals.cr` covers local variables, method parameters, receiver inference from `Type.new`, and scope boundaries.

`src/future.cr` is a stable playground for navigation not implemented yet. Markers named `FUTURE` document behavior to add without changing this fixture.

The fixture includes no dependencies and is intentionally not an application. It exists to make `gd` testing repeatable.
