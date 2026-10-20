import { argv } from "std/process";
import { readFile } from "std/fs";
import { Document } from "../src/model/document";
import { Syntax } from "../src/syntax/syntax";

const RUNS: int32 = 20;
const LINES: int32 = 40;

function microsecondsEach(start: float64): int32 {
	return ((performance.now() - start) * 1000.0 / (RUNS as float64)) as int32;
}

const source = readFile(argv[argv.length - 1]);
if (!source.ok) { throw new Error(`syntaxBench: ${source.error.message}`); }
const doc = new Document(source.value);
const syntax = new Syntax();
let start = performance.now();
syntax.sync(doc);
const parsed = (performance.now() - start) as int32;
console.log(`parse: ${parsed} ms for ${doc.length()} bytes, ${doc.lineCount()} lines`);
for (const line of [10, doc.lineCount() / 2, doc.lineCount() - 10]) {
	const at = doc.lineStart(line);
	start = performance.now();
	for (let i = 0; i < RUNS; i++) {
		const _e = doc.splice({ from: at, to: at, text: " " });
		syntax.sync(doc);
	}
	console.log(`keystroke and reparse at line ${line}: ${microsecondsEach(start)} us`);
	const end = doc.lineEnd(Math.min(line + LINES, doc.lineCount() - 1));
	start = performance.now();
	for (let i = 0; i < RUNS; i++) { const _tones = syntax.tonesIn(doc, at, end); }
	console.log(`tones of ${LINES} lines: ${microsecondsEach(start)} us`);
}
