#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/env.sh

for trip_tool in node npm forge; do
  if ! command -v "$trip_tool" >/dev/null 2>&1; then
    printf 'Missing tool: %s. See README.md.\n' "$trip_tool" >&2
    exit 1
  fi
done
if [ ! -d node_modules/@openzeppelin/upgrades-core ]; then
  printf '%s\n' 'Install dependencies first: npm ci' >&2
  exit 1
fi

# Keep upgrade validation reproducible and prevent npx from fetching another version.
export npm_config_offline=true
forge fmt --check
forge clean
forge build
forge test -vv

