# medic

A code editor on Neon + Void. Workspace rules: `~/metascript/CLAUDE.md`; style:
`~/metascript/docs/CODE-STYLE.md`.

## Layers

- `src/text`, `src/model`, `src/view/viewport.ms` are headless: they import nothing from Neon,
  Void or Ion, so the core runs and tests on every target and a vim layer, LSP or remote host can
  drive it later. Only `src/app` touches Neon.
- Every document change goes through one choke point (the document's splice), which returns the
  inverse edit, bumps the version and maps anchors and selections. Undo, the edit log and later
  LSP sync hang off it; a second write path desynchronises all three.
- Offsets are UTF-16 code units, the unit MetaScript strings index by, IME reports in and LSP
  defaults to. Grapheme boundaries are computed for movement, never stored.
- A per-frame cost is bounded by the viewport, never by the document size.

## Build and run

Run from the repository root: fonts are loaded by relative path.

- Desktop (Ion window, Windows): `msc build src/app/medic.ms --output=out/medic.exe`, then
  `out/medic.exe <file>`.
- Web (`runCanvas`, `--os=emcc`): `sh scripts/buildWeb.sh [gl] [wgpu]` writes `out/web/`; serve
  that directory and open `index.html` (`?gl` / `?wgpu` force a backend).
- Drive the web build headless: `node scripts/webDrive.mjs <url> <outDir> <step>...`.

## Gate

`msc test` on every file under `src/` that holds tests, then both builds above. WebGPU has no
adapter in headless Chrome on this machine, so it builds but renders only in a headed browser.
