import { WASI, File, PreopenDirectory, OpenFile, ConsoleStdout } from "https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.4.2/dist/index.js";

// Internal state for the WASI environment
const virtualFiles = new Map();
const virtualDir = new PreopenDirectory("/", virtualFiles);

// Expose a function to configure and return the WASI environment
export function createWasiEnvironment() {
    const fds = [
        new OpenFile(new File([])),
        ConsoleStdout.lineBuffered(msg => console.log("[hledger-wasm]", msg)),
        ConsoleStdout.lineBuffered(msg => console.error("[hledger-wasm]", msg)),
        virtualDir,
    ];

    return new WASI([], [], fds, { debug: false });
}

// The external API for your user application
export const BridgeStorage = {
    setFile(path, content) {
        virtualFiles.set(path, new File(new TextEncoder().encode(content)));
    },

    getFile(path) {
        const file = virtualFiles.get(path);
        return file ? new TextDecoder().decode(file.data) : null;
    },

    deleteFile(path) {
        virtualFiles.delete(path);
    },

    clear() {
        virtualFiles.clear();
    },

    list() {
        return Array.from(virtualFiles.keys());
    }
};