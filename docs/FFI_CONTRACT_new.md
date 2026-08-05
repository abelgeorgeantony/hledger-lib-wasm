# FFI Contract

## Purpose
Defines the interface between the JavaScript host and the hledger WASM reactor module. The design is based only on verified findings from the implementation investigation.

## Architecture
- Reactor-mode wasm32-wasi module.
- Long-lived instance.
- JSFFI exports.
- Virtual filesystem via PreopenDirectory.
- Journal parsed once, reused via opaque handles.

## Verified design decisions
- Use `parseAndFinaliseJournal` instead of file-based readers.
- Use `parseAndValidateCsvRules` for CSV rules.
- `createPipe` is unsupported on wasm32-wasi.
- Reactor mode and mutable virtual filesystem were experimentally verified.
- Virtual files can be added, replaced and removed after instantiation.

## Lifecycle
1. Initialise runtime once.
2. Register virtual files.
3. Parse journal/CSV.
4. Receive handle.
5. Run reports repeatedly.
6. Free handle.
7. Clear virtual files before unrelated sessions.

## API

### setVirtualFile(path, content)
Registers or replaces a virtual file.

### clearVirtualFiles()
Clears all virtual files.

### parseJournal(text)
Returns:
- `{ok:true,handle:int}`
- `{ok:false,error:string}`

Supports include directives through registered virtual files.

### parseCsv(csvText,rulesText)
Same return shape.

### runReport(handle,name)
Supported reports:
- accounts
- balance
- check

Invalid handle:
`{ok:false,error:"invalid handle"}`

### freeJournal(handle)
Releases stored journal.

## Handle semantics
Handles are opaque JS identifiers. JS must free every successful parse exactly once.

## Include handling
Literal includes are supported through the virtual filesystem. Missing includes return parser errors. Recursive includes work by retrying after missing files are populated. Glob includes remain unverified and should be considered unsupported until tested.

## Out of scope
- timeclock/timedot
- multi-file `-f`
- automatic CSV rule lookup

## Testing requirements
- Parse once, multiple reports.
- Invalid handle.
- Free/load cycles.
- Include resolution.
- Memory leak regression.
