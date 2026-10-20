import { argv, exit } from "std/process";
import { Document } from "../src/model/document";
import { allMatches } from "../src/model/find";
import { columnOf } from "../src/model/motion";
import { Viewport, scrolledBy } from "../src/view/viewport";
import { rowPieces, rowsOf } from "../src/view/wrap";

const DOCUMENT_BUDGET_MS = 1000;
const KEYSTROKE_BUDGET_US = 1000;
const FRAME_BUDGET_US = 2000;
const ROWS: int32 = 40;
const COLS: int32 = 60;

const mb = parseInt(argv[argv.length - 1]) as int32;
const line = "const value = compute(alpha, beta) + 42; // tiếng Việt, emoji 😀 ở đây\r\n";
const parts: string[] = [];
const count = (mb * 1024 * 1024) / line.byteLength;
for (let i = 0; i < count; i++) { parts.push(line); }
const text = parts.join("");
parts.setLength(0);

let over = 0;
function report(what: string, took: number, budget: number, unit: string): void {
	if (took > budget) { over += 1; }
	console.log(`${what}: ${took} ${unit}, budget ${budget} ${unit}${took > budget ? ", OVER" : ""}`);
}

let t0 = Date.now();
const doc = new Document(text);
report(`document of ${doc.length()} bytes, ${doc.lineCount()} lines`, Date.now() - t0, DOCUMENT_BUDGET_MS, "ms");

const rowsIn = (at: int32): int32 => rowsOf(doc, at, COLS).length as int32;
let view: Viewport = { line: doc.lineCount() / 2, sub: 0, left: 0, rows: ROWS, cols: COLS, pending: 0 };
let sum = 0;
t0 = Date.now();
for (let frame = 0; frame < 100; frame++) {
	view = view.scrolledBy(3, doc.lineCount(), rowsIn);
	let drawn = 0;
	for (let at = view.line; at < doc.lineCount() && drawn < ROWS; at++) {
		const rows = rowsOf(doc, at, COLS);
		for (let k = at == view.line ? view.sub : 0; k < (rows.length as int32) && drawn < ROWS; k++) {
			for (const p of rowPieces(doc, rows[k], 0, COLS, [], 0)) { sum += p.text.byteLength; }
			drawn += 1;
		}
	}
	sum += columnOf(doc, doc.lineEnd(view.line + 20));
}
report("scroll frame: 3 rows down, 40 wrapped rows drawn, a caret column", (Date.now() - t0) * 10, FRAME_BUDGET_US, "us");

const top = doc.lineCount() / 2;
t0 = Date.now();
for (let i = 0; i < 1000; i++) {
	const at = doc.lineStart(top) + 5;
	const _e = doc.splice({ from: at, to: at, text: "ư" });
}
report("keystroke", Date.now() - t0, KEYSTROKE_BUDGET_US, "us");

t0 = Date.now();
const hits = allMatches(doc, "beta) + 42").length;
console.log(`find all: ${Date.now() - t0} ms for ${hits} matches`);
t0 = Date.now();
sum += doc.fileText().byteLength;
console.log(`file text for a save, CRLF restored: ${Date.now() - t0} ms (${sum})`);

if (over > 0) {
	console.log(`openBench: ${over} over budget`);
	exit(1);
}
