import { argv } from "std/process";
import { readFile } from "std/fs";
import { Document } from "../src/model/document";
import { Syntax } from "../src/syntax/syntax";

const r = readFile(argv[argv.length - 1]);
if (!r.ok) { throw new Error("read failed"); }
const doc = new Document(r.value);
const s = new Syntax();
let t0 = Date.now();
s.sync(doc);
console.log(`parse: ${Date.now() - t0} ms for ${doc.length()} bytes, ${doc.lineCount()} lines`);
for (const line of [10, doc.lineCount() / 2, doc.lineCount() - 10]) {
	const at = doc.lineStart(line);
	t0 = Date.now();
	for (let i = 0; i < 20; i++) {
		const _e = doc.splice({ from: at, to: at, text: " " });
		s.sync(doc);
	}
	console.log(`keystroke and reparse at line ${line}: ${(Date.now() - t0) * 50} us`);
	t0 = Date.now();
	let n = 0;
	for (let f = 0; f < 20; f++) { n += s.tonesIn(doc, at, doc.lineEnd(Math.min(line + 40, doc.lineCount() - 1))).length; }
	console.log(`tones of 40 lines: ${(Date.now() - t0) * 50} us`);
}
