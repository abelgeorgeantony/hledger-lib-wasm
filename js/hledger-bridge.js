import {
  WASI,
  WASIProcExit,
  File,
  ConsoleStdout,
  PreopenDirectory,
  OpenFile,
} from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.4.2/dist/index.js";

let compiledModule = null;
let wasmBytes = null;

const isLocalDev = window.location.protocol === "file:" || window.location.hostname === "localhost" || window.location.hostname === "127.0.0.1";
const wasmUrl = isLocalDev
  ? "./wasm/hledger-wasm-final.wasm.gz"
  : "https://cdn.jsdelivr.net/gh/abelgeorgeantony/hledger-lib-wasm@main/wasm/hledger-wasm-final.wasm.gz";


export function configureHledgerWasm(options = {}) {
  if (options.wasmModule) {
    compiledModule = options.wasmModule;
    wasmBytes = null;
    return;
  }

  if (options.wasmBytes) {
    compiledModule = null;
    wasmBytes = options.wasmBytes;
  }

  if (options.wasmUrl) {
    compiledModule = null;
    wasmUrl = options.wasmUrl;
  }
}

export async function loadHledgerWasmFromFile(file) {
  configureHledgerWasm({ wasmBytes: await file.arrayBuffer() });
}

export async function loadHledgerWasmFromUrl(url) {
  configureHledgerWasm({ wasmUrl: url });
}

export function resetCompiledModule() {
  compiledModule = null;
}

export async function getCompiledModule() {
  if (!compiledModule) {
    compiledModule = await WebAssembly.compile(await getWasmBytes());
  }
  return compiledModule;
}

async function getWasmBytes() {
  if (wasmBytes) {
    return wasmBytes;
  }

  const response = await fetch(wasmUrl);
  if (!response.ok) {
    throw new Error(`Failed to fetch ${wasmUrl}: ${response.status}`);
  }
  const decompressed = response.body.pipeThrough(new DecompressionStream("gzip"));
  const bytes = await new Response(decompressed).arrayBuffer();
  return bytes;
}

async function runHledger(journalText, command, ...args) {
  let stdout = "";
  let stderr = "";

  const encoder = new TextEncoder();
  const fds = [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((line) => {
      stdout += `${line}\n`;
    }),
    ConsoleStdout.lineBuffered((line) => {
      stderr += `${line}\n`;
    }),
    new PreopenDirectory("/", [
      [
        "journal.hledger",
        new File(encoder.encode(journalText), { readonly: true }),
      ],
    ]),
  ];

  const wasi = new WASI(
    ["hledger-wasm", command, "/journal.hledger", ...args],
    [],
    fds,
  );
  const module = await getCompiledModule();
  const instance = await WebAssembly.instantiate(module, {
    wasi_snapshot_preview1: wasi.wasiImport,
  });

  try {
    const exitCode = wasi.start(instance);
    if (exitCode !== 0) {
      throw new Error(stderr.trim() || `hledger-wasm exited with ${exitCode}`);
    }
  } catch (error) {
    if (error instanceof WASIProcExit && error.code !== 0) {
      throw new Error(stderr.trim() || `hledger-wasm exited with ${error.code}`);
    }
    if (!(error instanceof WASIProcExit)) {
      throw error;
    }
  }

  if (stderr.trim()) {
    throw new Error(stderr.trim());
  }

  return stdout.trim();
}

export async function accounts(journalText) {
  return JSON.parse(await runHledger(journalText, "accounts"));
}

export async function balance(journalText) {
  return JSON.parse(await runHledger(journalText, "balance"));
}

export async function check(journalText) {
  return JSON.parse(await runHledger(journalText, "check"));
}

export { runHledger };
