# Crystal Navigation Demo

Manual fixture for Crystal navigation features. Open this directory in Neovim, call `require("crystal-nvim").setup()`, then place the cursor on marked identifiers and press `gd`.

`src/usage.cr` exercises definitions currently supported by crystal.nvim, including module and `lib` aliases. Each target has one unambiguous declaration in `src/declarations.cr`, except the marked picker example.

Place the cursor on `String` in the `PICKER` line and press `gd` to inspect project and standard-library labels.

`src/declarations.cr` includes `Dashboard#show` examples marked `GI`. Press `<localleader>i` on `draw` to jump to the superclass implementation and on `refresh` to jump to the included-module implementation.

`src/ambiguous.cr` intentionally has two `Widget` declarations. A bare `Widget` outside a namespace opens the selection UI; a qualified name does not.

`src/locals.cr` covers local variables, method parameters, receiver inference from `Type.new`, and scope boundaries.

`src/future.cr` is a stable playground for navigation not implemented yet. Markers named `FUTURE` document behavior to add without changing this fixture.

The fixture includes no dependencies and is intentionally not an application. It exists to make `gd` testing repeatable.
