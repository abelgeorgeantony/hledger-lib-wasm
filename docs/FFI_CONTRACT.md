# hledger-wasm FFI Contract — v2 (Option B: include directives supported)

## Exported functions

### setVirtualFile
Input:  (JSString path, JSString content)
Output: none
Notes:
  - Registers or overwrites a fake file the Haskell side can "read" via an
    `include` directive, before parseJournal/parseCsv is called.
  - Must be called for every file an `include` line might reference, ahead of
    the parse call that needs it — the parser has no way to ask for a file
    it wasn't given in advance.

### clearVirtualFiles
Input:  none
Output: none
Notes:
  - Removes all previously registered virtual files.
  - MUST be called between unrelated journal loads. Without this, a
    previously registered file could silently satisfy an `include` in a
    later, unrelated journal that happens to reference the same path —
    a correctness bug, not just a memory-tidiness one.

### parseJournal
Input:  JSString — raw journal text
Output: {"ok": true, "handle": <int>} | {"ok": false, "error": <string>}
Notes:
  - Any `include` line is resolved against files previously registered via
    setVirtualFile. An `include` referencing a path nothing was registered
    for fails with a clear parse error, not a crash.
  - Format is always native hledger journal syntax. No auto-detection.

### parseCsv
Input:  (JSString csvText, JSString rulesText)
Output: same shape as parseJournal
Notes:
  - `include` lines inside rulesText resolve the same way, via
    setVirtualFile — same requirement as parseJournal.

### runReport
Input:  (Int handle, JSString reportName)
Output: {"ok": true, "data": <report-specific JSON>} | {"ok": false, "error": <string>}
Supported reportName values: "accounts", "balance", "check"
  - "check" MUST invoke real validation (e.g. balance-assertion checking) —
    not a hardcoded {"ok": true}.
Behavior on invalid/freed handle: {"ok": false, "error": "invalid handle"}

### freeJournal
Input:  Int handle
Output: none
Notes:
  - Every successful parseJournal/parseCsv call must be matched by exactly
    one freeJournal call.

## Call ordering requirement (new in v2)
setVirtualFile (zero or more times) → clearVirtualFiles is NOT automatic →
parseJournal/parseCsv → runReport (any number of times) → freeJournal.
JS is responsible for calling clearVirtualFiles before starting a new,
unrelated journal load.

## Open dependency
This entire `include`-support design depends on the reactor-mode +
PreopenDirectory test passing. If that test fails, this contract reverts
to v1 (Option A — includes unsupported, documented limitation) until a
different mechanism is found.

## Explicitly out of scope for v1/v2
- timeclock/timedot formats
- multi-file journals via `-f a -f b` (readJournalFiles equivalent)
- CSV rules file auto-lookup by filename convention

## Versioning
v2 supersedes v1. Any further change to function signatures, JSON shapes,
or call-ordering rules bumps this number.