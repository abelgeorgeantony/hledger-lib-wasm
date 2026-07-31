#!/usr/bin/env bash
set -euo pipefail

source ~/.ghc-wasm/env
rm -rf wasm dist-newstyle

for tool in wasm32-wasi-cabal wasm-opt gzip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$tool' not found on PATH." >&2
    exit 1
  fi
done

mkdir -p wasm

echo "==> Building hledger-wasm..."
wasm32-wasi-cabal build hledger-wasm

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

# Generate the JSFFI glue AFTER optimization, against the exact file that
# actually ships — not the raw pre-optimization build. This guarantees the
# glue and the binary it's paired with are always the same artifact.
echo "==> Generating JSFFI glue..."
$(wasm32-wasi-ghc --print-libdir)/post-link.mjs \
  -i wasm/hledger-wasm-optimized.wasm \
  -o wasm/hledger-wasm-final.js

echo "==> Compressing for delivery..."
gzip -9 -k -c wasm/hledger-wasm-optimized.wasm > wasm/hledger-wasm-final.wasm.gz

echo ""
echo "==> Build complete. Size report:"
printf "  raw:        %s\n" "$(du -h wasm/hledger-wasm.wasm | cut -f1)"
printf "  optimized:  %s\n" "$(du -h wasm/hledger-wasm-optimized.wasm | cut -f1)"
printf "  compressed: %s\n" "$(du -h wasm/hledger-wasm-final.wasm.gz | cut -f1)"
printf "  glue (js):  %s\n" "$(du -h wasm/hledger-wasm-final.js | cut -f1)"