import { argv } from "std/process";
import { Document } from "../src/model/document";
import { columnOf } from "../src/model/motion";
import { rowText, rowsOf } from "../src/view/wrap";

const mb = parseInt(argv[argv.length - 1]) as int32;
const line = "const value = compute(alpha, beta) + 42; // tiếng Việt, emoji 😀 ở đây\r\n";
const parts: string[] = [];
const count = (mb * 1024 * 1024) / line.byteLength;
for (let i = 0; i < count; i++) { parts.push(line); }
const text = parts.join("");
parts.setLength(0);

let t0 = Date.now();
const doc = new Document(text);
console.log(`Document: ${Date.now() - t0} ms for ${doc.length()} bytes, ${doc.lineCount()} lines`);

const top = doc.lineCount() / 2;
let sum = 0;
t0 = Date.now();
for (let frame = 0; frame < 100; frame++) {
	for (let i = 0; i < 40; i++) {
		const rows = rowsOf(doc, top + i, 60);
		for (const r of rows) { sum += rowText(doc, r, 0, 60).byteLength; }
	}
	const head = doc.lineEnd(top + 20);
	sum += columnOf(doc, head) + doc.lineOf(head);
}
console.log(`frame, 40 wrapped lines drawn and a caret column: ${(Date.now() - t0) * 10} us`);

t0 = Date.now();
for (let i = 0; i < 1000; i++) {
	const at = doc.lineStart(top) + 5;
	const _e = doc.splice({ from: at, to: at, text: "ư" });
}
console.log(`keystroke: ${Date.now() - t0} us (${sum})`);
