#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
nvim --headless -u "$SCRIPT_DIR/minimal_init.lua" -c "PlenaryBustedFile $SCRIPT_DIR/endwise_spec.lua" "$@"
