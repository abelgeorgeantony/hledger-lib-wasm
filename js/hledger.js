const isLocalDev = window.location.protocol === "file:" || window.location.hostname === "localhost" || window.location.hostname === "127.0.0.1";
const wasmUrlPrefix = isLocalDev
  ? "../wasm/"
  : "https://cdn.jsdelivr.net/gh/abelgeorgeantony/hledger-lib-wasm@main/wasm/";


import { WASI, File, OpenFile, ConsoleStdout } from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.4.2/dist/index.js";
const { default: ghc_wasm_jsffi } = await import(`${wasmUrlPrefix}hledger-wasm-final.js`);

// Shared across every HledgerSession — instantiating the WASM module is
// expensive and has no per-session state of its own (all session state
// lives in Haskell's journalTable, keyed by handle), so it only needs to
// happen once for the whole page, no matter how many sessions exist.
let sharedInstancePromise = null;

function getSharedInstance() {
  if (!sharedInstancePromise) {
    sharedInstancePromise = (async () => {
      const fds = [
        new OpenFile(new File([])),
        ConsoleStdout.lineBuffered(msg => console.log("[hledger-wasm]", msg)),
        ConsoleStdout.lineBuffered(msg => console.error("[hledger-wasm]", msg)),
      ];
      const wasi = new WASI([], [], fds, { debug: false });
      const instance_exports = {};

      const compressed = await fetch((wasmUrlPrefix + "hledger-wasm-final.wasm.gz"));
      const decompressed = compressed.body.pipeThrough(new DecompressionStream("gzip"));
      const bytes = await new Response(decompressed).arrayBuffer();

      const { instance } = await WebAssembly.instantiate(bytes, {
        wasi_snapshot_preview1: wasi.wasiImport,
        ghc_wasm_jsffi: ghc_wasm_jsffi(instance_exports),
      });
      Object.assign(instance_exports, instance.exports);
      wasi.initialize(instance);

      return instance;
    })();
  }
  return sharedInstancePromise;
}

export class HledgerSession {
  #instance = null;
  #handle = null;

  // Constructors can't be async in JS, so creation goes through this
  // factory instead — the class is unusable until the shared WASM
  // instance has finished loading.
  static async create() {
    const session = new HledgerSession();
    session.#instance = await getSharedInstance();
    return session;
  }

  get isLoaded() {
    return this.#handle !== null;
  }

  async loadJournal(journalText) {
    await this.#freeCurrentHandle();
    const result = JSON.parse(await this.#instance.exports.parseJournal(journalText));
    if (result.ok) this.#handle = result.handle;
    return result;
  }

  

  async #runReport(name, query = "") {
    if (this.#handle === null) return { ok: false, error: "no journal loaded" };
    return JSON.parse(await this.#instance.exports.runReport(this.#handle, name, query));
  }

  async accounts(query = "") { return this.#runReport("accounts", query); }
  async balance(query = "") { return this.#runReport("balance", query); }
  async check(query = "") { return this.#runReport("check", query); }
  async register(query = "") { return this.#runReport("register", query); }
  async print(query = "") { return this.#runReport("print", query); }
  async prices(query = "") { return this.#runReport("prices", query); }
  async payees(query = "") { return this.#runReport("payees", query); }
  async commodities(query = "") { return this.#runReport("commodities", query); }
  async tags(query = "") { return this.#runReport("tags", query); }
  async balancesheet(query = "") { return this.#runReport("balancesheet", query); }
  async incomestatement(query = "") { return this.#runReport("incomestatement", query); }
  async cashflow(query = "") { return this.#runReport("cashflow", query); }



  async #freeCurrentHandle() {
    if (this.#handle !== null) {
      await this.#instance.exports.freeJournal(this.#handle);
      this.#handle = null;
    }
  }

  async dispose() {
    await this.#freeCurrentHandle();
  }
}