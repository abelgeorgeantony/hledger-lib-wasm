# Set up hledger WASM project

> I am trying to create a browser only and google drive journal storage based PTA implementation. First I need a reliable hledger-lib wasm port. Below is a simple guide produced by claude after some backandforth qna sessions. Do basic repo setup on this repo based on the below guide.
> ---
>
> ## Phase 1 — Tooling & Project Setup
>
> ### 1.1 Install the GHC WASM toolchain
> Same as before — this part didn't change:
> ```bash
> curl https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta/-/raw/master/bootstrap.sh | sh
> source ~/.ghc-wasm/env
> ```
> (Recall: `haskell-wasm/ghc-wasm-meta` is the current repo location — it moved from the old `ghc/ghc-wasm-meta` path.)
>
> ### 1.2 Project layout — simpler than before, since hledger-lib stays untouched
>
> ```
> hledger-wasm/
>   vendor/
>     hledger/              # git submodule, pinned to a tag — used COMPLETELY UNMODIFIED
>   stubs/                  # fake replacement packages for anything that won't build for WASM
>     terminal-size/
>       terminal-size.cabal
>       System/Console/Terminal/Size.hs
>   bridge/                 # the Haskell CLI program that becomes the .wasm file
>     hledger-wasm-bridge.cabal
>     Main.hs
>   js/
>     hledger-bridge.js     # the JavaScript side that runs the .wasm file in a browser
>   cabal.project
> ```
>
> The key difference from my original plan: there's no `patches/` folder anymore, because we're not editing hledger-lib's source at all. `vendor/hledger` stays a clean, unmodified checkout, forever. The only place we do anything unusual is `stubs/` and `bridge/`.
>
> ### 1.3 Set up the submodule
> ```bash
> git submodule add https://github.com/simonmichael/hledger.git vendor/hledger
> cd vendor/hledger && git checkout <pinned-tag> && cd ../..
> ```
>
> ### 1.4 `cabal.project` — wire in the stub packages
>
> ```yaml
> packages:
>   bridge
>   stubs/terminal-size
>   vendor/hledger/hledger-lib
> ```
>
> Cabal (the Haskell build tool) resolves dependencies by package name — if `stubs/terminal-size` declares itself as package `terminal-size` version `0.3.4`, and hledger-lib says "I depend on `terminal-size`," Cabal will use **your fake local one** instead of fetching the real one from Hackage (Haskell's package repository). Nothing in hledger-lib needs to know or care.
>
> ---
>
> ## Phase 2 — Providing "stand-in" packages for anything WASM can't build
>
> This replaces the old "patch hledger-lib" phase entirely. The idea: some of hledger-lib's *dependencies* — not hledger-lib itself — assume things that don't exist in a browser (a real terminal, in this case). Instead of patching hledger-lib to stop calling those dependencies, you write a tiny fake version of the dependency that satisfies the same function names but does something harmless.
>
> ### 2.1 The one confirmed example: `terminal-size`
>
> hledger-lib uses this small library to detect terminal width, for formatting CLI report tables. There's no terminal in a browser, so the real answer is always "I don't know the width." Here's the actual fake package that solves it:
>
> ```haskell
> -- stubs/terminal-size/System/Console/Terminal/Size.hs
> module System.Console.Terminal.Size
>     ( Window(..)
>     , size
>     , hSize
>     , fdSize
>     ) where
>
> import System.IO (Handle)
>
> data Window a = Window { height :: !a, width :: !a } deriving (Eq, Show, Read)
>
> size :: Integral n => IO (Maybe (Window n))
> size = return Nothing        -- "I don't know the terminal size" — always fine to say
>
> hSize :: Integral n => Handle -> IO (Maybe (Window n))
> hSize _ = return Nothing
>
> fdSize :: Integral n => Int -> IO (Maybe (Window n))
> fdSize _ = return Nothing
> ```
>
> ```haskell
> -- stubs/terminal-size/terminal-size.cabal
> cabal-version:      2.4
> name:               terminal-size
> version:            0.3.4
> build-type:         Simple
>
> library
>   exposed-modules:  System.Console.Terminal.Size
>   build-depends:    base >=4 && <5
>   hs-source-dirs:   .
>   default-language: Haskell2010
> ```
>
> Notice: the module name, function names, and types exactly match the real `terminal-size` package's public interface. That's the whole trick — same shape, different (do-nothing) insides.
>
> ### 2.2 How to find out if you need more of these
>
> You won't know until you actually try to build. This is a **discovery loop**, not a checklist:
>
> ```bash
> wasm32-wasi-cabal build hledger-lib 2>&1 | tee build.log
> ```
>
> Read the errors. If you see something like `cannot find package X for wasm32-wasi` or a link error mentioning a specific package's C code, that's your next candidate for a stub. Not every failing package needs a full fake reimplementation — sometimes the fix is simpler (a newer version of the same package on Hackage already fixed the WASM problem, so you just need a version bump in `cabal.project`'s constraints). Try the version bump first; write a stub only if no working version exists.
>
> **Important honesty note:** we only have hard evidence that `terminal-size` needed this treatment (that's the one real stub `reesericci`'s project used). We don't have proof their build ever fully succeeded (no CI ran it, no `dist/` binary was ever committed), so treat that stub list as "confirmed necessary" but **not necessarily complete** — you may hit one or two more when you actually run the build yourself, and this loop is how you'd handle them.
>
> ### 2.3 Keep a short log of why each stub exists
>
> ```
> stubs/README.md
> ```
> One line per stub: which real package it replaces, and why the real one doesn't work in WASM. Six months from now, if a real fixed version of that package appears on Hackage, this note tells you whether it's safe to delete your stub and use the real thing again.
>
> ---
>
> ## Phase 3 — Building hledger-lib for WASM
>
> This phase is now much shorter than in my original plan, because there's no patch-application step — you're building **vanilla, unmodified hledger-lib**.
>
> ```bash
> wasm32-wasi-cabal build hledger-lib --dependencies-only
> ```
>
> If a dependency fails and it's not a "needs a stub" situation (Phase 2) but a genuine build failure (some C code that assumes a normal operating system), the options are:
> 1. Check if hledger-lib has a way to disable that feature via a Cabal "flag" (a build-time on/off switch some packages expose) — some Haskell packages let you turn off optional functionality this way, which sometimes sidesteps the offending dependency entirely
> 2. Check if a newer/older version of the troublesome dependency drops the problematic bit
> 3. As a last resort, write a stub (Phase 2's technique) for that dependency too
>
> Once it builds cleanly:
> ```bash
> wasm32-wasi-cabal build hledger-lib
> ```
> You're done with this phase — hledger-lib's parser, its data types (`Transaction`, `Posting`, `Journal`), and its existing JSON-encoding support are now compiled to WASM, completely unmodified from upstream.
>
> ---
>
> ## Phase 4 — Exposing it: the CLI-in-a-box approach
>
> This is the part that changes the most from my original plan. Instead of writing special "export this function to JavaScript" code (the FFI/StablePtr approach), you write a **completely ordinary command-line Haskell program** — the kind you'd run on a normal computer — and let the browser pretend to be that computer.
>
> ### 4.1 The Haskell side: a normal CLI program
>
> ```haskell
> -- bridge/Main.hs
> {-# LANGUAGE OverloadedStrings #-}
> module Main where
>
> import qualified Data.Aeson as Aeson
> import qualified Data.ByteString.Lazy.Char8 as BLC
> import System.Environment (getArgs)
> import System.IO (hFlush, stdout, stderr, hPutStrLn)
> import Control.Monad.Except (runExceptT)
> import Hledger
> import Hledger.Read (readJournalFile)
>
> main :: IO ()
> main = do
>   args <- getArgs
>   case args of
>     (cmd:file:rest) -> do
>       result <- runExceptT $ readJournalFile definputopts file
>       case result of
>         Left err -> hPutStrLn stderr ("Parse error: " ++ err)
>         Right j  -> runCommand cmd j rest
>     _ -> hPutStrLn stderr "Usage: hledger-wasm <command> <file> [args...]"
>
> runCommand :: String -> Journal -> [String] -> IO ()
> runCommand "accounts" j _ = do
>   BLC.putStrLn (Aeson.encode (journalAccountNames j))
>   hFlush stdout
> -- ... more commands (balance, print, aregister, etc.)
> ```
>
> **Important improvement over what I found in the reference project:** it hand-rolled its own simplistic balance calculation (`sumPostings` over filtered postings) instead of calling hledger-lib's *actual* report engine. I'd recommend calling the real thing instead, since it's already there and already handles multi-currency, tree hierarchies, and date ranges correctly:
>
> ```haskell
> import Hledger.Reports.BalanceReport (balanceReport)
>
> runCommand "balance" j _ = do
>   let report = balanceReport defreportspec j   -- reuses hledger's real logic
>   BLC.putStrLn (Aeson.encode report)
> ```
> This gets you hledger's actual report quality "for free," instead of reimplementing a thinner version of it yourself.
>
> Compile it as a normal WASI program — notice there's **no special flags for reactor mode or exports** this time, since it's just an ordinary program:
> ```bash
> wasm32-wasi-cabal build hledger-wasm
> ```
>
> ### 4.2 The JavaScript side: pretending to be a computer for it
>
> The browser needs a stand-in for "a real operating system" so this program can run at all. That's what `@bjorn3/browser_wasi_shim` (an npm package) provides — it answers the small set of OS-like requests (open a file, read/write, exit) that WASI-compiled programs are allowed to make.
>
> ```bash
> npm install @bjorn3/browser_wasi_shim
> ```
>
> ```js
> // js/hledger-bridge.js
> import { WASI, File, ConsoleStdout, PreopenDirectory, OpenFile } from "@bjorn3/browser_wasi_shim";
>
> let compiledModule = null;   // cache this — see the fix below
>
> async function getCompiledModule() {
>   if (!compiledModule) {
>     const bytes = await (await fetch("/wasm/hledger-wasm.wasm")).arrayBuffer();
>     compiledModule = await WebAssembly.compile(bytes);   // compile ONCE
>   }
>   return compiledModule;
> }
>
> async function runHledger(journalText, command, ...args) {
>   let stdout = "";
>   const fds = [
>     new OpenFile(new File([])),                                  // stdin (unused)
>     ConsoleStdout.lineBuffered((msg) => { stdout += msg + "\n"; }), // capture stdout
>     ConsoleStdout.lineBuffered((msg) => console.error("[hledger]", msg)), // stderr -> console
>     new PreopenDirectory("/", new Map([
>       ["journal.hledger", new File(new TextEncoder().encode(journalText))],
>     ])),
>   ];
>
>   const wasi = new WASI(["hledger-wasm", command, "/journal.hledger", ...args], [], fds);
>   const module = await getCompiledModule();                       // reuse the cached compile
>   const instance = await WebAssembly.instantiate(module, {
>     wasi_snapshot_preview1: wasi.wasiImport,
>   });
>
>   wasi.initialize(instance);
>   try { instance.exports._start(); } catch (e) { /* normal program exit, ignore */ }
>
>   return stdout.trim();
> }
>
> export async function balance(journalText) {
>   return JSON.parse(await runHledger(journalText, "balance"));
> }
> export async function accounts(journalText) {
>   return JSON.parse(await runHledger(journalText, "accounts"));
> }
> ```
>
> **The fix I mentioned earlier:** the reference project re-downloaded and re-compiled the `.wasm` file on *every single call*. `WebAssembly.compile` is the expensive step (turning the raw bytes into something the browser can actually run); `WebAssembly.instantiate`-from-an-already-compiled-module is cheap. Caching `compiledModule` once and reusing it for every call (as above) avoids redoing that expensive step every time someone clicks a button.
>
> ### 4.3 What "writing to the journal" looks like in this design
>
> Here's a genuinely good thing about this approach: **there's no persistent session to manage.** Every call is a fresh, independent run of the program — you hand it the full journal text (including your new candidate transaction, appended as a string on the JS side) and it re-parses everything from scratch, the same way the real command-line `hledger` tool does every time you run it. This isn't a limitation you're accepting — it's literally how hledger already works natively. So "writing a transaction" is just: build the new journal string in JS (as I described a few messages back), then call a `check`/`balance`-style command against the *whole* updated string to validate it, no special "session" or "handle" bookkeeping needed at all.
>
> ---
>
> ## Phase 5 — Testing
>
> This phase matters more now, precisely because we found the reference project had **no testing at all** (no CI, no verified build, no committed binary).
>
> ### 5.1 First, confirm it actually builds and runs — don't skip this
> ```bash
> wasm32-wasi-cabal build hledger-wasm
> find dist-newstyle -name "hledger-wasm.wasm"
> ```
> Try running it under a command-line WASI runtime (`wasmtime`) before ever touching a browser — much faster to debug:
> ```bash
> wasmtime --dir=. dist-newstyle/.../hledger-wasm.wasm -- accounts myjournal.hledger
> ```
>
> ### 5.2 Golden-file comparison against real hledger
> ```bash
> for f in vendor/hledger/tests/journals/*.journal; do
>   native=$(hledger -f "$f" balance)
>   wasm=$(node scripts/run-wasm.mjs "$f" balance)
>   diff <(echo "$native") <(echo "$wasm") || echo "MISMATCH: $f"
> done
> ```
> This is especially important now since you're replacing hledger's real report engine calls in `Main.hs` — you want proof the JSON you get back actually matches what real hledger computes, not just that it runs without crashing.
>
> ### 5.3 Actually add CI — this is the gap the reference project had
> ```yaml
> # .github/workflows/build.yml
> - run: wasm32-wasi-cabal build hledger-wasm
> - run: node scripts/run-wasmtime-tests.mjs
> - run: npx playwright test    # real browser test, not just wasmtime
> ```
>
> ### 5.4 Browser test for the module-caching fix specifically
> Worth a dedicated test that calls the bridge multiple times in a row and confirms only one `fetch`/`compile` happens (e.g., by spying on `fetch` in a Playwright test) — this is exactly the kind of regression that's easy to silently reintroduce later.

<details><summary>44 previous messages</summary>

> I’ll take a quick look at the repo shape first, then I’ll lay down the minimal project scaffolding from the guide and only reach for networked submodule setup if it’s actually needed.
>
> <details><summary>Explored a list, ran 2 commands</summary>
>
> - Ran `pwd`
>
> <details><summary>Explored a list</summary>
>
> - Listed files
>
> </details>
>
> - Ran `git status --short`
>
> </details>
>
> `rg` isn’t installed here, so I’m falling back to plain filesystem reads. I also see `README.md` is already modified; I’ll leave that alone unless the setup needs a separate note file.
>
> <details><summary>Explored 2 searches, ran a command, searched the web</summary>
>
> <details><summary>Explored 2 searches</summary>
>
> - Searched for `./.git/*` in `.`
> - Searched for `./.git*` in `.`
>
> </details>
>
> - Ran `git diff -- README.md`
>
> Searched the web for `github simonmichael hledger releases latest tag`
>
> </details>
>
> I’m going to pin the upstream checkout to the latest stable hledger release I found, `1.52.1`, instead of the 2.0 preview line. Next I’ll try adding the submodule; if the sandbox blocks network access, I’ll request that specific permission.
>
> The submodule add hit the sandbox’s read-only `.git` boundary, which is expected here because submodules update the git index as well as the working tree. I’ll ask for that one operation with escalation so the repo metadata can be updated normally.
>
> <details><summary>Ran 2 commands</summary>
>
> - Ran `git submodule add https://github.com/simonmichael/hledger.git vendor/hledger`
> - Ran `git -C vendor/hledger checkout 1.52.1`
>
> </details>
>
> The submodule is in place and now detached at `1.52.1`. I’m reading hledger’s cabal files next so the bridge package names and dependencies match the actual vendored version instead of guessing.
>
> <details><summary>Explored a file, 2 searches, ran a command</summary>
>
> <details><summary>Explored a file, a search</summary>
>
> - Read `./vendor/hledger/hledger-lib/hledger-lib.cabal`
> - Searched for `*.cabal` in `hledger`
>
> </details>
>
> - Ran `git status --short`
>
> <details><summary>Explored a search</summary>
>
> - Searched for `*.hs` in `Hledger`
>
> </details>
>
> </details>
>
> One small wrinkle: `git submodule add` staged the initial submodule pointer automatically, and checking out the tag made that staged pointer stale. I’ll fix the index pointer after the file scaffold is done so the repo reflects the intended `1.52.1` pin cleanly.
>
> <details><summary>Explored a file, 3 searches</summary>
>
> - Searched for `journalAccountNames` in `Hledger`
> - Searched for `definputopts` in `Hledger`
> - Searched for `balanceReport` in `Reports`
> - Read `./vendor/hledger/hledger-lib/Hledger.hs`
>
> </details>
>
> The vendored `hledger-lib` exports the modules we need (`Hledger`, `Hledger.Read`, and the report modules), so I can keep the bridge deliberately small: parse a journal, expose `accounts`, `balance`, and `check`, and leave fuller report parity for the next build/test discovery loop.
>
> <details><summary>Explored 3 files, a search</summary>
>
> - Read `./vendor/hledger/hledger-lib/Hledger/Reports/BalanceReport.hs`
> - Read `./vendor/hledger/hledger-lib/Hledger/Reports/ReportOptions.hs`
> - Searched for `instance .*ToJSON` in `Data`
> - Read `./vendor/hledger/hledger-lib/Hledger/Read.hs`
>
> </details>
>
> Before editing, here’s the concrete setup I’m applying: a root `cabal.project`, an unmodified hledger submodule under `vendor/hledger`, a `terminal-size` shim, a small Haskell executable package named `hledger-wasm`, and a browser WASI JS helper with module caching.
>
> <details><summary>Explored 3 files, ran 5 commands, searched the web</summary>
>
> - Ran `command -v cabal`
>
> - Ran `command -v wasm32-wasi-cabal`
>
> - Ran `command -v wasmtime`
>
> - Ran `command -v npm`
>
> <details><summary>Explored 3 files</summary>
>
> - Read `./vendor/hledger/hledger-lib/Hledger/Data/Json.hs`
> - Read `./vendor/hledger/hledger-lib/Hledger/Data.hs`
> - Read `./vendor/hledger/hledger-lib/Hledger/Reports.hs`
>
> </details>
>
> Searched the web for `npm @bjorn3/browser_wasi_shim version`
>
> - Ran `command -v ghc`
>
> </details>
>
> I’m creating the scaffold now. I’m keeping the Haskell bridge conservative so it depends on hledger-lib’s public API and returns JSON for the first browser-facing operations without inventing a custom accounting layer.
>
> <details><summary>Ran a command</summary>
>
> - Ran `mkdir -p bridge stubs/terminal-size/System/Console/Terminal js scripts wasm`
>
> </details>
>
> I’m adding the project files next: Cabal wiring, the terminal-size replacement, the bridge executable, JS wrapper, and a small `.gitignore`/stub note so future build-discovery work has a clear starting point.
>
> <details><summary>Created 9 files</summary>
>
> - Wrote `./.gitignore` (+3 -0)
> - Wrote `./bridge/Main.hs` (+49 -0)
> - Wrote `./bridge/hledger-wasm.cabal` (+18 -0)
> - Wrote `./cabal.project` (+12 -0)
> - Wrote `./js/hledger-bridge.js` (+89 -0)
> - Wrote `./package.json` (+8 -0)
> - Wrote `./stubs/README.md` (+3 -0)
> - Wrote `./stubs/terminal-size/System/Console/Terminal/Size.hs` (+24 -0)
> - Wrote `./stubs/terminal-size/terminal-size.cabal` (+12 -0)
>
> </details>
>
> The first pass of files is down. I’m doing a couple of housekeeping checks now: make sure the submodule pointer is the pinned tag in the index, generate the npm lock if the registry is reachable, then inspect the resulting diff for obvious mistakes.
>
> <details><summary>Ran a command</summary>
>
> - Ran `git add vendor/hledger`
>
> </details>
>
> The submodule pointer is now synced to the tag. I’m going to create only a package lock for the browser shim dependency, not install `node_modules`, so the repo stays light.
>
> <details><summary>Ran a command</summary>
>
> - Ran `npm install --package-lock-only`
>
> </details>
>
> `npm install --package-lock-only` is still running, likely waiting on registry access. I’ll give it a moment, then I’ll either use the produced lockfile or request network permission if it clearly can’t reach npm from the sandbox.
>
> The npm command hasn’t returned after a minute, so this is behaving like a network stall rather than local work. I’ll stop that sandboxed attempt and rerun it with the explicit approval path.
>
> <details><summary>Ran a command</summary>
>
> - Ran `npm install --package-lock-only`
>
> </details>
>
> The npm lockfile is generated and cleanly audited. I’m doing static sanity checks now, including JS syntax and the final git/submodule state; the Haskell build itself depends on the GHC WASM toolchain, which this environment doesn’t currently have.
>
> <details><summary>Ran 5 commands</summary>
>
> - Ran `git submodule status`
> - Ran `git diff --cached --stat`
> - Ran `git status --short`
> - Ran `node --check js/hledger-bridge.js`
> - Ran `git diff --stat`
>
> </details>
>
> The JS file passes Node syntax checking, and the submodule reports exactly `3834a163… (1.52.1)`. I noticed one Haskell import/operator detail I want to tidy before calling this done.
>
> <details><summary>Edited a file, explored 4 files, ran a command</summary>
>
> - Wrote `./bridge/Main.hs` (+2 -1)
>
> <details><summary>Explored 4 files</summary>
>
> - Read `./js/hledger-bridge.js`
> - Read `./cabal.project`
> - Read `./bridge/Main.hs`
> - Read `./package-lock.json`
>
> </details>
>
> - Ran `git diff -- . ':(exclude)README.md'`
>
> </details>
>
> I’m going to add a short root README section too. The existing README only had the title plus a newline, so this is a low-risk place to record the setup/build commands without touching upstream hledger.
>
> <details><summary>Edited a file</summary>
>
> - Wrote `./README.md` (+33 -0)
>
> </details>
>
> The README now records the repo layout and the minimal build path. I’m doing the final status/diff check and will flag anything I couldn’t verify locally.
>
> <details><summary>Explored a list, ran 4 commands</summary>
>
> - Ran `git diff -- README.md`
>
> - Ran `git diff --cached`
>
> <details><summary>Explored a list</summary>
>
> - Listed files in `bridge`
>
> </details>
>
> - Ran `git status --short`
>
> - Ran `node --check js/hledger-bridge.js`
>
> </details>
>
> One tiny polish: since the JS wrapper expects `/wasm/hledger-wasm.wasm`, I’m keeping the `wasm/` directory trackable while still ignoring generated `.wasm` binaries.
>
> <details><summary>Created a file</summary>
>
> - Wrote `./wasm/.gitkeep` (+1 -0)
>
> </details>
>
> The setup files are in place. I’m running one last status check so the handoff is crisp.
>
> <details><summary>Explored a search, ran 3 commands</summary>
>
> <details><summary>Explored a search</summary>
>
> - Searched for `./.git/*` in `.`
>
> </details>
>
> - Ran `git status --short`
>
> - Ran `git submodule status`
>
> - Ran `node --check js/hledger-bridge.js`
>
> </details>
>
> One quick API sanity check remains: I’m confirming `definputopts` is exported through `Hledger.Read` exactly as the bridge imports it, because that’s the sort of small Cabal-era mismatch that is annoying later.
>
> <details><summary>Explored 2 files, 2 searches</summary>
>
> - Read `./vendor/hledger/hledger-lib/Hledger/Read.hs`
> - Read `./vendor/hledger/hledger-lib/Hledger/Read/InputOptions.hs`
> - Searched for `module Hledger.Read` in `Read.hs`
> - Searched for `System.Console.Terminal.Size` in `hledger-lib`
>
> </details>
>
> I’m adding two small npm scripts as ergonomics: one for the WASM build command and one for the JS syntax check I used.
>
> <details><summary>Edited a file</summary>
>
> - Wrote `./package.json` (+4 -0)
>
> </details>
>
> The scripts are in. I’ll run the JS check through npm now and then I’m done with verification.
>
> <details><summary>Ran 3 commands</summary>
>
> - Ran `git submodule status`
> - Ran `git status --short`
> - Ran `npm run check:js`
>
> </details>
</details>

Done. Basic scaffold is in place.

Set up:
- hledger submodule at `vendor/hledger`, pinned to `1.52.1` commit `3834a163...`
- [cabal.project](./cabal.project) wiring `bridge`, `stubs/terminal-size`, and vanilla `vendor/hledger/hledger-lib`
- [terminal-size WASM stub](./stubs/terminal-size/System/Console/Terminal/Size.hs)
- [Haskell bridge executable](./bridge/Main.hs) with `accounts`, `balance`, and `check`
- [browser WASI JS wrapper](./js/hledger-bridge.js) with cached `WebAssembly.compile`
- `package.json` / lockfile for `@bjorn3/browser_wasi_shim`
- README setup notes and `.gitignore`

Verified:
- `npm install --package-lock-only`
- `npm run check:js`
- `git submodule status` shows `vendor/hledger (1.52.1)`

I could not run the actual WASM build because `wasm32-wasi-cabal` is not installed in this environment yet.

Sources used for current pins: hledger GitHub releases and npm’s `@bjorn3/browser_wasi_shim` package page.

> What should be done next? Give step by step instruction untill I can call this to an html document in browser and load a journal and see output.

Yes. Next goal is: prove the WASM executable works, copy it into `wasm/`, then serve a tiny browser page that calls `js/hledger-bridge.js`.

**Step By Step**

1. Install/activate GHC WASM:

```bash
curl https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta/-/raw/master/bootstrap.sh | sh
source ~/.ghc-wasm/env
```

Check:

```bash
wasm32-wasi-cabal --version
wasm32-wasi-ghc --version
```

2. Install JS dependency:

```bash
npm install
```

3. Build dependencies first:

```bash
wasm32-wasi-cabal update
wasm32-wasi-cabal build hledger-wasm --dependencies-only 2>&1 | tee build.log
```

If this fails, inspect `build.log`. This is where we discover whether `terminal-size` was enough or whether another dependency needs a version constraint/stub.

4. Build the WASM executable:

```bash
wasm32-wasi-cabal build hledger-wasm
```

5. Copy the built `.wasm` file into the browser-served folder:

```bash
mkdir -p wasm
cp "$(find dist-newstyle -name 'hledger-wasm.wasm' -print -quit)" wasm/hledger-wasm.wasm
```

6. Add a simple browser demo file, `index.html`:

```html
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>hledger WASM demo</title>
  </head>
  <body>
    <input id="file" type="file" />
    <button id="accounts">Accounts</button>
    <button id="balance">Balance</button>
    <pre id="output"></pre>

    <script type="module">
      import { accounts, balance } from "./js/hledger-bridge.js";

      let journalText = "";

      document.querySelector("#file").addEventListener("change", async (event) => {
        journalText = await event.target.files[0].text();
        document.querySelector("#output").textContent = "Loaded journal.";
      });

      document.querySelector("#accounts").addEventListener("click", async () => {
        const result = await accounts(journalText);
        document.querySelector("#output").textContent = JSON.stringify(result, null, 2);
      });

      document.querySelector("#balance").addEventListener("click", async () => {
        const result = await balance(journalText);
        document.querySelector("#output").textContent = JSON.stringify(result, null, 2);
      });
    </script>
  </body>
</html>
```

7. Use Vite so the browser can resolve the npm import:

```bash
npm install --save-dev vite
npx vite --host 127.0.0.1
```

8. Open the printed Vite URL, usually:

```text
http://127.0.0.1:5173/
```

9. Load a journal file like:

```journal
2026-01-01 opening
  assets:bank        $100
  equity:opening    -$100

2026-01-02 coffee
  expenses:food       $5
  assets:bank
```

Then click `Accounts` or `Balance`.

The key next checkpoint is step 3. If `wasm32-wasi-cabal build hledger-wasm --dependencies-only` fails, that error log decides the next stub/constraint work.

> Why are we using npm and its modules and vite? this is a simple html only calling application there is no server.

Fair pushback. I suggested `npm`/Vite because of one browser mechanics issue, not because the app needs a backend.

The Haskell `.wasm` is compiled as a WASI CLI program. In the browser, it needs a WASI shim: something that pretends to provide stdin/stdout/filesystem. The guide uses `@bjorn3/browser_wasi_shim`, which is an npm package.

Vite was only a convenience for two things:

1. Browsers do not understand bare imports like:

```js
import { WASI } from "@bjorn3/browser_wasi_shim";
```

unless something resolves that package name.

2. Browsers usually cannot reliably `fetch("./wasm/hledger-wasm.wasm")` from a plain `file://` opened HTML file. A static HTTP server avoids that.

But you are right: there is no need for an application server, framework, or Vite-specific app.

Better options:

**Option A: Static Site, No Backend**
Use any dumb static file server:

```bash
python3 -m http.server 8080
```

Then open:

```text
http://127.0.0.1:8080/
```

This is still “HTML only” in the sense that there is no backend logic. It just lets the browser load JS and WASM correctly.

**Option B: No npm During Runtime**
Bundle or vendor the WASI shim once, then use only local files:

```text
index.html
js/hledger-bridge.js
js/vendor/browser-wasi-shim.js
wasm/hledger-wasm.wasm
```

Then `hledger-bridge.js` imports the shim relatively instead of from npm.

**Option C: CDN Import**
No npm, simplest prototype:

```js
import {
  WASI,
  File,
  ConsoleStdout,
  PreopenDirectory,
  OpenFile,
} from "https://esm.sh/@bjorn3/browser_wasi_shim@0.4.2";
```

Downside: the page depends on internet/CDN availability.

So the cleaned-up recommendation is:

1. Keep `@bjorn3/browser_wasi_shim` as the required WASI compatibility layer.
2. Do not use Vite unless you want bundling convenience.
3. For a simple local demo, use a plain `index.html` plus `python3 -m http.server`.
4. Later, vendor/bundle the shim so the final app is just static files.

Literal double-click `file://index.html` is likely to be unreliable because of browser module/WASM loading rules. A static server is the boring reliable path.

> Aren't you understanding what I am saying? This will be a static site! I cannot use imports like in npm. Either html or client side js should load everything and do every processing in client side only!

<details><summary>25 previous messages</summary>

> You’re right; I blurred “static site” with “npm-based frontend workflow,” and that was not what you asked for. I’m going to adjust the repo so the browser code imports only local static files, with no bare npm imports and no Vite requirement.
>
> The target shape I’m aiming for is: `index.html` loads `./js/hledger-bridge.js`; that file imports `./vendor/browser-wasi-shim/...` locally; all accounting work runs in the browser against `./wasm/hledger-wasm.wasm`. No app server, no bundler, no npm package resolution in the page.
>
> <details><summary>Ran a command</summary>
>
> - Ran `npm pack @bjorn3/browser_wasi_shim@0.4.2 --pack-destination /tmp`
>
> </details>
>
> The package download is stalling under the sandbox’s network restrictions, so I’ll request permission once to fetch the WASI shim and vendor it into the repo. This is just to make the final site independent of npm imports.
>
> <details><summary>Ran a command</summary>
>
> - Ran `npm pack @bjorn3/browser_wasi_shim@0.4.2 --pack-destination /tmp`
>
> </details>
>
> I’ve got the shim tarball. I’m inspecting its published `dist/` shape, then I’ll copy only the browser JS distribution and licenses into `js/vendor/`.
>
> <details><summary>Ran 6 commands</summary>
>
> - Ran `tar -xOf /tmp/bjorn3-browser_wasi_shim-0.4.2.tgz package/dist/index.js`
> - Ran `tar -tf /tmp/bjorn3-browser_wasi_shim-0.4.2.tgz | sort`
> - Ran `tar -xOf /tmp/bjorn3-browser_wasi_shim-0.4.2.tgz package/package.json`
> - Ran `mkdir -p js/vendor/browser-wasi-shim`
> - Ran `tar -xf /tmp/bjorn3-browser_wasi_shim-0.4.2.tgz -C js/vendor/browser-wasi-shim --strip-components=2 package/dist/index.js package/dist/wasi.js package/dist/wasi_defs.js package/dist/fd.js package/dist/fs_mem.js package/dist/fs_opfs.js package/dist/debug.js package/dist/strace.js`
> - Ran `tar -xf /tmp/bjorn3-browser_wasi_shim-0.4.2.tgz -C js/vendor/browser-wasi-shim --strip-components=1 package/LICENSE-APACHE package/LICENSE-MIT package/README.md`
>
> </details>
>
> I’m also going to make the bridge able to accept a `File`/`ArrayBuffer` for the `.wasm` instead of requiring `fetch("/wasm/...")`. That gives you two static modes: deployed static site can fetch the local `.wasm`, and a plain HTML page can let the user choose the `.wasm` file explicitly.
>
> <details><summary>Explored 3 files</summary>
>
> - Read `./js/vendor/browser-wasi-shim/fs_mem.js`
> - Read `./js/vendor/browser-wasi-shim/wasi.js`
> - Read `./js/vendor/browser-wasi-shim/index.js`
>
> </details>
>
> I’m removing the npm manifest from this scaffold and switching the bridge to a local vendored shim import. The final static page will not contain any `@package/name` imports.
>
> <details><summary>Edited a file, deleted 2 files</summary>
>
> - Wrote `./js/hledger-bridge.js` (+119 -2)
> - Deleted `./package-lock.json` (+0 -18)
> - Deleted `./package.json` (+0 -12)
>
> </details>
>
> I’m checking that patch because the bridge file had enough moving parts that I want to make sure it didn’t leave duplicate functions behind.
>
> <details><summary>Explored a file</summary>
>
> - Read `./js/hledger-bridge.js`
>
> </details>
>
> Good catch in the check: the file had duplicate trailing code from the previous version. I’m replacing it cleanly now.
>
> <details><summary>Created a file</summary>
>
> - Wrote `./js/hledger-bridge.js` (+127 -0)
>
> </details>
>
> I’m adding a plain `index.html` demo now. It will work as static client code: pick a journal, optionally pick the built `.wasm` file, then run `check`, `accounts`, or `balance` entirely in the browser.
>
> <details><summary>Created a file, edited a file</summary>
>
> - Wrote `./README.md` (+7 -6)
> - Wrote `./index.html` (+264 -0)
>
> </details>
>
> The static demo is added, and README no longer tells you to install JS dependencies. I’m checking syntax and status now, including the vendored shim files.
>
> <details><summary>Explored a search, a list, ran 2 commands</summary>
>
> <details><summary>Explored a search, a list</summary>
>
> - Listed files in `browser-wasi-shim`
> - Searched for `./.git/*` in `.`
>
> </details>
>
> - Ran `git status --short`
>
> - Ran `node --check js/hledger-bridge.js`
>
> </details>
>
> I’m doing one last sweep for npm/Vite references and package files so the instructions match the static-site design instead of drifting back into frontend-tooling land.
>
> <details><summary>Explored a search, ran 2 commands</summary>
>
> <details><summary>Explored a search</summary>
>
> - Searched for `npm\|vite\|@bjorn3/browser_wasi_shim` in `README.md`
>
> </details>
>
> - Ran `git diff -- README.md js/hledger-bridge.js index.html .gitignore cabal.project bridge/Main.hs bridge/hledger-wasm.cabal stubs/README.md stubs/terminal-size/terminal-size.cabal stubs/terminal-size/System/Console/Terminal/Size.hs`
>
> - Ran `git diff --stat`
>
> </details>
>
> The only remaining npm mentions are inside the upstream vendored shim README, so I’m replacing that with a tiny local vendor note plus keeping the actual license files. That keeps the repo’s own guidance consistent.
>
> <details><summary>Created a file</summary>
>
> - Wrote `./js/vendor/browser-wasi-shim/README.md` (+5 -0)
>
> </details>
>
> I’m checking again; after that I’ll give you the corrected no-npm/no-Vite steps.
>
> <details><summary>Explored a search, a list, ran 2 commands</summary>
>
> <details><summary>Explored a search, a list</summary>
>
> - Searched for `npm\|vite\|@bjorn3/browser_wasi_shim` in `README.md`
> - Listed files in `browser-wasi-shim`
>
> </details>
>
> - Ran `git status --short`
>
> - Ran `node --check js/hledger-bridge.js`
>
> </details>
</details>

You’re right. I misunderstood the constraint.

I changed the repo direction to a real static-site shape:

- No `npm` runtime dependency
- No Vite
- No bare import like `@bjorn3/browser_wasi_shim`
- WASI shim is vendored locally in `js/vendor/browser-wasi-shim/`
- `index.html` calls local client-side JS only

Use it like this:

1. Install/activate GHC WASM:

```bash
curl https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta/-/raw/master/bootstrap.sh | sh
source ~/.ghc-wasm/env
```

2. Build the WASM executable:

```bash
wasm32-wasi-cabal build hledger-wasm
```

3. Copy the built WASM into the static folder:

```bash
cp "$(find dist-newstyle -name 'hledger-wasm.wasm' -print -quit)" wasm/hledger-wasm.wasm
```

4. Open [index.html](./index.html) in the browser.

5. In the page:
- Select `wasm/hledger-wasm.wasm` in the “WASM file” picker if browser local-file loading blocks `./wasm/hledger-wasm.wasm`
- Select a journal file, or edit the sample journal text
- Click `Check`, `Accounts`, or `Balance`
- Output appears in the page

The important correction: `js/hledger-bridge.js` now imports this local file:

```js
./vendor/browser-wasi-shim/index.js
```

not an npm package.

I also removed the `package.json` / lockfile from the scaffold.
