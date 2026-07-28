#!/usr/bin/env bash
set -euo pipefail
# -e: stop immediately if any command fails
# -u: treat using an unset variable as an error
# -o pipefail: catch failures inside a pipeline (e.g. `find | something`), not just the last command

source ~/.ghc-wasm/env

rm -rf wasm dist-newstyle

# Fail fast with a clear message if a required tool is missing,
# instead of a confusing error halfway through the script.
for tool in wasm32-wasi-cabal wasm-opt gzip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$tool' not found on PATH." >&2
    exit 1
  fi
done

mkdir -p wasm   # defensive — directory should already exist, but costs nothing to be sure

echo "==> Building hledger-wasm..."
wasm32-wasi-cabal build hledger-wasm

# Find the built .wasm file, and actually check we found one —
# the old script's `cp` would fail with a confusing error on an empty result.
BUILT_WASM="$(find dist-newstyle -name 'hledger-wasm.wasm' -print -quit)"
if [ -z "$BUILT_WASM" ]; then
  echo "ERROR: build succeeded but no hledger-wasm.wasm was found under dist-newstyle." >&2
  exit 1
fi

cp "$BUILT_WASM" wasm/hledger-wasm.wasm

echo "==> Optimizing with wasm-opt..."
wasm-opt -Oz --strip-debug --strip-producers -c \
  -o wasm/hledger-wasm-optimized.wasm \
  wasm/hledger-wasm.wasm

echo "==> Compressing for delivery..."
gzip -9 -k -c wasm/hledger-wasm-optimized.wasm > wasm/hledger-wasm-final.wasm.gz

# Print a size report — the whole point of this pipeline is shrinking the file,
# so show the actual before/after numbers instead of just trusting it worked.
echo ""
echo "==> Build complete. Size report:"
printf "  raw:        %s\n" "$(du -h wasm/hledger-wasm.wasm | cut -f1)"
printf "  optimized:  %s\n" "$(du -h wasm/hledger-wasm-optimized.wasm | cut -f1)"
printf "  compressed: %s  <- this is what js/hledger-bridge.js actually fetches\n" "$(du -h wasm/hledger-wasm-final.wasm.gz | cut -f1)"
