# medic

A code editor on Neon + Void. Workspace rules: `~/metascript/CLAUDE.md`; style:
`~/metascript/docs/CODE-STYLE.md`.

The repository is public (`github.com/metascriptlang/medit`). Tracked text, commit messages
included, names no editor or project medic took a design from, because a reader of a public
repository takes a named source as copied code: describe the behaviour itself, and keep design
sources and their `file:line` anchors in the arc card under `~/metascript/.wt/`. Vendored
dependencies with their licences and medic's own stack (Neon, Void, Ion, recompiler) are named as
usual.

## Layers

- `src/text`, `src/model`, `src/input`, `src/view` are headless: they import nothing
  from Neon, Void or Ion, so the core runs and tests on every target and a vim layer, LSP or remote
  host can drive it later. Only `src/app` touches Neon.
- Every document change goes through one choke point (the document's splice), which returns the
  inverse edit, bumps the version and maps anchors and selections. Undo, the edit log and later
  LSP sync hang off it; a second write path desynchronises all three.
- Offsets are UTF-8 bytes. MetaScript's UTF-16 string calls (`length`, `slice`, `charCodeAt`)
  walk the string on non-ASCII text, while the byte tier (`byteAt`, `byteSlice`, `byteLength`) does
  not, so the rope and every model API index by byte; UTF-16, which LSP speaks, is converted at
  that edge, within a line. Grapheme boundaries are computed for movement, never stored.
- The rope (`src/text/rope.ms`) is a persistent B-tree of UTF-8 leaves: an edit copies its path
  and shares the rest, so a kept root is a snapshot. Its hot paths use index loops, because a
  `for-of` over a node array measured twice as slow.
- Cluster and cell walks (`src/text/clusters.ms`) run over a line's bytes, read from the rope once:
  a frame of 40 wrapped lines took 3.6 ms through the rope's `byteAt` against 0.2 ms over line bytes
  (100 MB, release, 2026-10-20). Columns, wrap, drawing and clicks share that one width function.
- A per-frame cost is bounded by the viewport, never by the document size.
- The document holds LF only: `splice` turns inserted CRLF into LF, and `fileText` gives a file
  back CRLF when its first line break was CRLF. A lone CR stays and draws as ␍. A desktop save
  writes `<path>.medic-save` and renames it over the file, so a failed write leaves the file whole.
- Bracket matching (`src/model/brackets.ms`) scans bytes within `BRACKET_REACH` of the caret and
  counts brackets inside strings and comments too; the syntax tree can tell them apart once it
  covers every language medic opens.
- `src/syntax` compiles vendored C: the tree-sitter runtime and recompiler's MetaScript grammar,
  versions in `vendor/SOURCES`.
  `sh scripts/vendorSyntax.sh` re-vendors both and regenerates `src/syntax/highlights.ms`. The C
  runtime does not evaluate query predicates, so `Syntax` evaluates `#any-of?`, `#lua-match?` and
  `#eq?` itself and refuses any other by name.
- Highlighting stops above `HIGHLIGHT_LIMIT` (`src/app/app.ms`) because parsing runs on the UI
  thread. `syntaxBench`, release, 2026-10-20: a first parse runs at about 10 MB/s; one keystroke's
  reparse took 15 ms at 454 KB of recompiler source and 43-54 ms at 0.9 MB, against 7 ms at 2 MB of
  generated code that parses without errors. The grammar leaves error nodes in recompiler source
  (`~/metascript/.inbox/compiler/2026-10-20-tree-sitter-grammar-behind-the-language.md`), and those
  make the reparse slow; once it parses them, the limit can rise to about 2 MB. Larger files need
  parsing off the UI thread.
- `src/lsp` speaks the language server protocol over a `Link` (bytes in and out), so the headless
  session runs the same over a desktop child process (`src/app/lsp/processLink.ms`) and a page's
  WebSocket (`socketLink.ms`). `src/model/language.ms` names the server of each file type.
  A server's positions name the document version they were computed on; `DocumentSync` keeps the last
  `KEPT_VERSIONS` texts sent and maps through the edits since, and drops a reply whose version
  it no longer holds.

## Build and run

Run from the repository root: fonts are loaded by relative path.

- Desktop (Ion window, Windows): `msc build src/app/medic.ms --output=out/medic.exe`, then
  `out/medic.exe <file>`. Add `--release` to open large files: building the document of a 100 MB
  file took 0.25 s in release against 2.6 s in debug (2026-10-20).
- Open cost: `msc run --release scripts/openBench.ms -- <megabytes>` times the document build, a
  scroll frame, a keystroke, a find over the whole file and a save's file text on generated text,
  and exits 1 when one of the first three passes its `*_BUDGET_*` constant. At 100 MB on
  2026-10-20: document 281 ms, scroll frame 110 us, keystroke 10 us, file text 490 ms; the frame
  took 135 us on 2026-10-21 once it also looked for the brackets around its caret. Find of
  1.28 M matches on 2026-10-21: 113 ms exact, 269 ms ignoring case and taking whole words; the find
  bar counts every match on each keystroke, so these are its per-keystroke cost at that size.
- Highlight cost: `msc run --release scripts/syntaxBench.ms -- <file>` times the first parse, a
  keystroke's reparse at three places and the tones of 40 lines.
- Web (`runCanvas`, `--os=emcc`): `sh scripts/buildWeb.sh [gl] [wgpu]` writes `out/web/`; serve
  that directory and open `index.html` (`?gl` / `?wgpu` force a backend).
- Language server in the web build: `node scripts/lspBridge.mjs [port] [--trace] [-- command]`
  carries a server's stdio over a WebSocket (default port 8766, `msc lsp`); open
  `index.html?lsp=ws://127.0.0.1:8766`. The page's sample is `file:///medic/sample.ms`, which the
  server sees only through the protocol.
- Drive the web build headless: `node scripts/webDrive.mjs <url> <outDir> <step>...` (steps in its
  header). CDP `insertText` outside a composition is dropped by void's web input; type with `type:`.
- Drive the desktop build: `pwsh scripts/desktopDrive.ps1 out/medic.exe <file> <outDir> <step>...`
  (steps in its header, named as in `webDrive.mjs`). It sends messages to medic's own window, so the
  window needs no focus and the screenshots show only that window; keys reach the editor only after
  a `click:` on it.

## Gate

`sh scripts/gate.sh`: `msc test` on every file under `src/` that holds tests, the open bench at
100 MB, then both builds above; a land runs it with `wt.sh land --gate 'sh scripts/gate.sh'`. WebGPU has no
adapter in headless Chrome on this machine, so it builds but renders only in a headed browser.
