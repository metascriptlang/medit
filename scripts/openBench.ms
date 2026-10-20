import { argv, exit } from "std/process";
import { Document } from "../src/model/document";
import { enclosingBrackets } from "../src/model/brackets";
import { Query, allMatches, exact } from "../src/model/find";
import { columnOf } from "../src/model/motion";
import { Viewport, scrolledBy } from "../src/view/viewport";
import { rowPieces, rowsOf } from "../src/view/wrap";

const DOCUMENT_BUDGET_MS: int32 = 1000;
const KEYSTROKE_BUDGET_US: int32 = 1000;
const FRAME_BUDGET_US: int32 = 2000;
const FRAMES: int32 = 100;
const KEYSTROKES: int32 = 1000;
const ROWS: int32 = 40;
const COLS: int32 = 60;

function millisecondsSince(start: float64): int32 {
	return (performance.now() - start) as int32;
}

function microsecondsEach(start: float64, runs: int32): int32 {
	return ((performance.now() - start) * 1000.0 / (runs as float64)) as int32;
}

let over = 0;
function report(what: string, took: int32, budget: int32, unit: string): void {
	const isOver = took > budget;
	if (isOver) { over += 1; }
	console.log(`${what}: ${took} ${unit}, budget ${budget} ${unit}${isOver ? ", OVER" : ""}`);
}

const megabytes = parseInt(argv[argv.length - 1]) as int32;
const line = "const value = compute(alpha, beta) + 42; // tiếng Việt, emoji 😀 ở đây\r\n";
const text = line.repeat(megabytes * 1024 * 1024 / line.byteLength);

let start = performance.now();
const doc = new Document(text);
report(
	`document of ${doc.length()} bytes, ${doc.lineCount()} lines`,
	millisecondsSince(start),
	DOCUMENT_BUDGET_MS,
	"ms",
);

const rowsIn = (at: int32): int32 => rowsOf(doc, at, COLS).length;
let view: Viewport = {
	line: doc.lineCount() / 2,
	sub: 0,
	left: 0,
	rows: ROWS,
	cols: COLS,
	pending: 0,
};
let sum = 0;
start = performance.now();
for (let frame = 0; frame < FRAMES; frame++) {
	view = view.scrolledBy(3, doc.lineCount(), rowsIn);
	let drawn = 0;
	for (let at = view.line; at < doc.lineCount() && drawn < ROWS; at++) {
		const rows = rowsOf(doc, at, COLS);
		for (let k = at == view.line ? view.sub : 0; k < rows.length && drawn < ROWS; k++) {
			for (const piece of rowPieces(doc, rows[k], 0, COLS, [], 0)) {
				sum += piece.text.byteLength;
			}
			drawn += 1;
		}
	}
	const caret = doc.lineStart(view.line + 20);
	sum += columnOf(doc, doc.lineEnd(view.line + 20));
	sum += doc.enclosingBrackets(caret, caret) === null ? 0 : 1;
}
report(
	"scroll frame: 3 rows down, 40 wrapped rows drawn, a caret column, the brackets around it",
	microsecondsEach(start, FRAMES),
	FRAME_BUDGET_US,
	"us",
);

const top = doc.lineCount() / 2;
start = performance.now();
for (let i = 0; i < KEYSTROKES; i++) {
	const at = doc.lineStart(top) + 5;
	const _e = doc.splice({ from: at, to: at, text: "ư" });
}
report("keystroke", microsecondsEach(start, KEYSTROKES), KEYSTROKE_BUDGET_US, "us");

start = performance.now();
const hits = allMatches(doc, exact("beta) + 42")).length;
console.log(`find all: ${millisecondsSince(start)} ms for ${hits} matches`);
const loose: Query = { text: "BETA) + 42", caseSensitive: false, wholeWord: true };
start = performance.now();
const looseHits = allMatches(doc, loose).length;
console.log(`find all, any case, whole word: ${millisecondsSince(start)} ms for ${looseHits} matches`);
start = performance.now();
sum += doc.fileText().byteLength;
console.log(`file text for a save, CRLF restored: ${millisecondsSince(start)} ms (${sum})`);

if (over > 0) {
	console.log(`openBench: ${over} over budget`);
	exit(1);
}
