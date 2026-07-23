#!/usr/bin/env bash
# Run the kotlin-lite headless test suite.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec nvim --headless -u "$here/minimal_init.lua" -l "$here/run.lua"
