# hledger-lib-wasm

Static browser/WASI experiment for using vanilla `hledger-lib` from JavaScript.

## Layout

- `vendor/hledger` is the unmodified upstream hledger checkout, pinned as a git submodule.
- `stubs/` contains local replacement packages for dependencies that do not make sense in browser WASI.
- `bridge/` contains the small Haskell executable that parses a journal and emits JSON.
- `js/` contains the browser-side WASI bridge.
- `js/vendor/browser-wasi-shim/` contains the local static WASI shim used by the bridge.
- `wasm/` is the expected place to copy the built `hledger-wasm.wasm` for browser serving.

## Setup

Install and activate the GHC WASM toolchain:

```bash
curl https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta/-/raw/master/bootstrap.sh | sh
source ~/.ghc-wasm/env
```

Build the Haskell bridge:

```bash
wasm32-wasi-cabal build hledger-wasm
```

Then copy the produced `hledger-wasm.wasm` into `wasm/` for browser use:

```bash
cp "$(find dist-newstyle -name 'hledger-wasm.wasm' -print -quit)" wasm/hledger-wasm.wasm
```

Open `index.html` in a browser. If your browser blocks loading `./wasm/hledger-wasm.wasm` from a local file URL, use the WASM file picker in the page to select `wasm/hledger-wasm.wasm` directly.
