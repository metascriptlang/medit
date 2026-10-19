# medic

A code editor on Neon + Void. Workspace rules: `~/metascript/CLAUDE.md`; style:
`~/metascript/docs/CODE-STYLE.md`.

## Layers

- `src/text`, `src/model`, `src/input`, `src/view/viewport.ms` are headless: they import nothing
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
- A per-frame cost is bounded by the viewport, never by the document size.

## Build and run

Run from the repository root: fonts are loaded by relative path.

- Desktop (Ion window, Windows): `msc build src/app/medic.ms --output=out/medic.exe`, then
  `out/medic.exe <file>`. Add `--release` to open large files: building the document of a 100 MB
  file took 0.25 s in release against 2.6 s in debug (2026-10-20).
- Open cost: `msc run --release scripts/openBench.ms -- <megabytes>` times the document build, one
  frame's line reads and one keystroke on generated text.
- Web (`runCanvas`, `--os=emcc`): `sh scripts/buildWeb.sh [gl] [wgpu]` writes `out/web/`; serve
  that directory and open `index.html` (`?gl` / `?wgpu` force a backend).
- Drive the web build headless: `node scripts/webDrive.mjs <url> <outDir> <step>...` (steps in its
  header). CDP `insertText` outside a composition is dropped by void's web input; type with `type:`.

## Gate

`sh scripts/gate.sh`: `msc test` on every file under `src/` that holds tests, then both builds
above; a land runs it with `wt.sh land --gate 'sh scripts/gate.sh'`. WebGPU has no
adapter in headless Chrome on this machine, so it builds but renders only in a headed browser.
