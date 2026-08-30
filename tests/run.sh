#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
INIT_FILE="$SCRIPT_DIR/minimal_init.lua"
if [[ -n "${DEPS_DIR:-}" ]]; then
  INIT_FILE="$SCRIPT_DIR/ci_init.lua"
fi

nvim --headless -u "$INIT_FILE" -c "PlenaryBustedFile $SCRIPT_DIR/setup_spec.lua" "$@"
nvim --headless -u "$INIT_FILE" -c "PlenaryBustedFile $SCRIPT_DIR/ameba_spec.lua" "$@"
nvim --headless -u "$INIT_FILE" -c "PlenaryBustedFile $SCRIPT_DIR/endwise_spec.lua" "$@"
