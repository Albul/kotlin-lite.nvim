#!/usr/bin/env bash
# tests/vanilla/run.sh in Docker, once per Neovim release (default: the oldest
# supported, the last 0.11 and the current one). See tests/README.md.
#     tests/vanilla/docker.sh                  # v0.10.4 v0.11.7 v0.12.6
#     tests/vanilla/docker.sh v0.12.6 nightly
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
versions=("$@")
[ ${#versions[@]} -gt 0 ] || versions=(v0.10.4 v0.11.7 v0.12.6)

declare -A result
status=0
for v in "${versions[@]}"; do
    tag="kotlin-lite-vanilla:${v#v}"
    echo "=== $v"
    if ! docker build -q --build-arg NVIM_VERSION="$v" -t "$tag" "$repo/tests/vanilla" >/dev/null; then
        result[$v]="build failed"; status=1; continue
    fi
    if docker run --rm -v "$repo:/src:ro" "$tag"; then
        result[$v]="passed"
    else
        result[$v]="FAILED"; status=1
    fi
done

echo "=== summary"
for v in "${versions[@]}"; do printf '  %-10s %s\n' "$v" "${result[$v]}"; done
exit $status
