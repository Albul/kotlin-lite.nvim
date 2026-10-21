#!/usr/bin/env bash
# Smoke test without lazy.nvim / LazyVim, in a throwaway XDG home with nothing
# else on the 'runtimepath'. Scenarios:
#   zero-config  native package (pack/*/start), no init.lua, default mapleader
#   setup        native package, init.lua with mapleader = " " and setup({...}),
#                plus a gradle project
#   vim.pack     (Neovim 0.12+) installed by vim.pack.add() from init.lua
# tests/vanilla/docker.sh runs it against several Neovim releases.
# See tests/README.md.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="$repo/tests/vanilla/check.lua"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" \
    XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache"
unset NVIM_APPNAME VIMINIT NVIM_LOG_FILE

start="$XDG_DATA_HOME/nvim/site/pack/smoke/start"
mkdir -p "$XDG_CONFIG_HOME/nvim" "$start"
ln -s "$repo" "$start/kotlin-lite.nvim"

proj="$tmp/proj"
mkdir -p "$proj"
cp "$repo/tests/fixtures/Main.kt" "$repo/tests/fixtures/Geometry.kt" "$proj/"

gradle="$tmp/gradle"
mkdir -p "$gradle"
touch "$gradle/settings.gradle.kts" "$gradle/gradle.properties"

# --cmd runs before any config: record the notifications from startup on
run() { # scenario, extra lua for _G.SMOKE
    (cd "$proj" && nvim --headless \
        --cmd "lua _G.SMOKE = { scenario = '$1', notes = {} $2 }
            local notify = vim.notify
            vim.notify = function(msg, level, o)
                table.insert(_G.SMOKE.notes, { msg = msg, level = level or vim.log.levels.INFO })
                return notify(msg, level, o)
            end" \
        Main.kt -c "luafile $check")
}

status=0
run zero-config "" || status=1

cat > "$XDG_CONFIG_HOME/nvim/init.lua" <<'EOF'
vim.g.mapleader = " "
require("kotlin-lite").setup({ auto_sync = false })
EOF
run setup ", gradle = '$gradle'" || status=1

if [ "$(nvim --headless --clean +'lua io.stdout:write(vim.pack and "1" or "0")' +qa)" = 1 ]; then
    # vim.pack clones a git repo: a snapshot of the working tree, uncommitted
    # changes included, so it tests the same files the other scenarios do
    snap="$tmp/kotlin-lite.git"
    mkdir -p "$snap"
    (cd "$repo" && git ls-files -z --cached --others --exclude-standard \
        | tar --null --ignore-failed-read -T - -cf - 2>/dev/null) | tar -C "$snap" -xf -
    git -C "$snap" init -q && git -C "$snap" add -A \
        && git -C "$snap" -c user.name=smoke -c user.email=smoke@localhost commit -qm snapshot
    rm "$start/kotlin-lite.nvim"
    cat > "$XDG_CONFIG_HOME/nvim/init.lua" <<EOF
vim.g.mapleader = " "
vim.pack.add({ { src = "$snap", name = "kotlin-lite.nvim" } }, { confirm = false })
require("kotlin-lite").setup({ auto_sync = false })
EOF
    run vim.pack ", gradle = '$gradle', from = '/pack/core/opt/kotlin%-lite%.nvim/'" || status=1
else
    echo "[vim.pack] skipped: Neovim $(nvim --version | head -1) has no vim.pack"
fi

exit $status
