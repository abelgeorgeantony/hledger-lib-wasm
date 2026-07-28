# WASM Stub Packages

- `terminal-size` replaces the real terminal-size package because browser WASI has no terminal dimensions to query; returning `Nothing` matches the safe "unknown size" behavior hledger-lib can tolerate.
