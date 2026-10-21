import { argv } from "std/process";
import { QuickOpen } from "../src/model/quickOpen";

const WORDS = [
	"model", "view", "text", "app", "lsp", "syntax", "rope", "fuzzy", "palette", "tabs",
	"editor", "document", "selection", "motion", "history",
	"folds", "wrap", "cells", "theme", "server",
	"Parser", "Lexer", "Checker", "Emitter", "Transform",
	"Lowering", "Runtime", "Buffer", "Span", "Map",
];
const EXTENSIONS = [".ms", ".ts", ".c", ".h", ".md", ".json"];

let seed: int64 = 12345;
function pick(n: int32): int32 {
	seed = (seed * 48271) % 2147483647;
	return (seed % (n as int64)) as int32;
}

const count = argv.length > 2 ? parseInt(argv[argv.length - 1]) as int32 : 50000;
const paths: string[] = [];
for (let i = 0; i < count; i++) {
	let path = "";
	const depth = 1 + pick(4);
	for (let d = 0; d < depth; d++) { path += `${WORDS[pick(30)]}/`; }
	path += `${WORDS[pick(30)]}${WORDS[pick(30)]}${i}${EXTENSIONS[pick(6)]}`;
	paths.push(path);
}

const open = new QuickOpen((): void => {});
open.files(paths);
open.show();

function typing(query: string): void {
	open.query("");
	let line = `${query}:`;
	let worst: float64 = 0;
	for (let i = 1; i <= (query.byteLength as int32); i++) {
		const start = performance.now();
		open.query(query.byteSlice(0, i));
		const took = performance.now() - start;
		worst = Math.max(worst, took);
		line += ` ${(took * 10.0) as int32 / 10.0}`;
	}
	console.log(`${line} ms (worst ${(worst * 10.0) as int32 / 10.0}, ${open.rows().length} rows)`);
}

console.log(`${count} paths`);
typing("paletteview");
typing("tabs.ms");
typing("model/rope");
typing("ParserMap");
typing("e");
typing("zq");
