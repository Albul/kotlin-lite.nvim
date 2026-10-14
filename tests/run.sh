#!/usr/bin/env bash
# Run the kotlin-lite busted suite (see tests/README.md); extra args go to busted.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec nvim -l tests/minit.lua --busted -o utfTerminal "$@"
