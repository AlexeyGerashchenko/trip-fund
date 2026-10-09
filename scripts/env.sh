# Source this file from the project root: source scripts/env.sh
# Local tools take precedence when present; globally installed Foundry also works.
if [ ! -f foundry.toml ]; then
  printf '%s\n' 'Run this from the trip-fund project root.' >&2
  return 1
fi
export PATH="$PWD/.tools/bin:$PATH"
if [ -x "$PWD/.tools/bin/solc" ]; then
  export FOUNDRY_SOLC="$PWD/.tools/bin/solc"
fi
export npm_config_cache="$PWD/.tools/npm-cache"

