# medic

A code editor on Neon + Void. Workspace rules: `~/metascript/CLAUDE.md`; style:
`~/metascript/docs/CODE-STYLE.md`.

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

## Build and run

Run from the repository root: fonts are loaded by relative path.

- Desktop (Ion window, Windows): `msc build src/app/medic.ms --output=out/medic.exe`, then
  `out/medic.exe <file>`. Add `--release` to open large files: building the document of a 100 MB
  file took 0.25 s in release against 2.6 s in debug (2026-10-20).
- Open cost: `msc run --release scripts/openBench.ms -- <megabytes>` times the document build, one
  frame's line reads and one keystroke on generated text.
- Highlight cost: `msc run --release scripts/syntaxBench.ms -- <file>` times the first parse, a
  keystroke's reparse at three places and the tones of 40 lines.
- Web (`runCanvas`, `--os=emcc`): `sh scripts/buildWeb.sh [gl] [wgpu]` writes `out/web/`; serve
  that directory and open `index.html` (`?gl` / `?wgpu` force a backend).
- Drive the web build headless: `node scripts/webDrive.mjs <url> <outDir> <step>...` (steps in its
  header). CDP `insertText` outside a composition is dropped by void's web input; type with `type:`.

## Gate

`sh scripts/gate.sh`: `msc test` on every file under `src/` that holds tests, then both builds
above; a land runs it with `wt.sh land --gate 'sh scripts/gate.sh'`. WebGPU has no
adapter in headless Chrome on this machine, so it builds but renders only in a headed browser.
