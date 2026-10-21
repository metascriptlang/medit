import { Document } from "./document";
import { Query, allMatches } from "./find";
import { isTrail } from "../text/clusters";

export const MAX_RESULT_FILES: int32 = 5000;
export const MAX_RESULT_HITS: int32 = 10000;
export const HIT_TEXT_BYTES: int32 = 240;
const HIT_LEAD_BYTES: int32 = 40;
const BINARY_PROBE_BYTES: int32 = 8000;

export struct Hit {
	line: int32;
	from: int32;
	to: int32;
	text: string;
	textFrom: int32;
}

export struct FileHits {
	key: string;
	hits: Hit[];
}

export struct ProjectResults {
	files: FileHits[];
	matches: int32;
	limitReached: boolean;
}

function startOf(line: string, at: int32): int32 {
	let start = at;
	while (start > 0 && isTrail(line.byteAt(start))) { start -= 1; }
	return start;
}

function indentEnd(line: string): int32 {
	let at = 0;
	while (at < line.byteLength && (line.byteAt(at) == " ".code || line.byteAt(at) == "\t".code)) { at += 1; }
	return at;
}

export function hitOn(lineNumber: int32, line: string, from: int32, to: int32): Hit {
	let textFrom = Math.min(indentEnd(line), from);
	if (to - textFrom > HIT_TEXT_BYTES) { textFrom = startOf(line, Math.max(textFrom, from - HIT_LEAD_BYTES)); }
	const textTo = startOf(line, Math.min(line.byteLength as int32, textFrom + HIT_TEXT_BYTES));
	return { line: lineNumber, from, to, text: line.byteSlice(textFrom, textTo), textFrom };
}

export function looksBinary(text: string): boolean {
	return text.byteSlice(0, Math.min(text.byteLength as int32, BINARY_PROBE_BYTES)).byteIndexOf("\u0000") >= 0;
}

export function hitsIn(doc: Document, q: Query, room: int32): [Hit[], boolean] {
	const found = doc.allMatches(q);
	const hits: Hit[] = [];
	let lineNumber = -1;
	let start = 0;
	let line = "";
	for (const at of found) {
		if ((hits.length as int32) == room) { break; }
		if (lineNumber < 0 || at > doc.lineEnd(lineNumber)) {
			lineNumber = doc.lineOf(at);
			start = doc.lineStart(lineNumber);
			line = doc.line(lineNumber);
		}
		hits.push(hitOn(lineNumber, line, at - start, Math.min(line.byteLength as int32, at - start + (q.text.byteLength as int32))));
	}
	return [hits, found.length > hits.length];
}

function gathered(keys: string[], hitsOf: (key: string, room: int32) => [Hit[], boolean]): ProjectResults {
	const files: FileHits[] = [];
	let matches = 0;
	for (const key of keys) {
		if ((files.length as int32) == MAX_RESULT_FILES || matches == MAX_RESULT_HITS) {
			return { files, matches, limitReached: true };
		}
		const [hits, cut] = hitsOf(key, MAX_RESULT_HITS - matches);
		if (hits.length > 0) {
			files.push({ key, hits });
			matches += hits.length as int32;
		}
		if (cut) { return { files, matches, limitReached: true }; }
	}
	return { files, matches, limitReached: false };
}

export function searchProject(
	keys: string[],
	openDoc: (key: string) => Document | null,
	readText: (key: string) => string | null,
	q: Query,
): ProjectResults {
	return gathered(keys, (key: string, room: int32): [Hit[], boolean] => {
		const open = openDoc(key);
		if (open !== null) { return hitsIn(open as Document, q, room); }
		const text = readText(key);
		if (text === null || looksBinary(text as string)) { return [[], false]; }
		return hitsIn(new Document(text as string), q, room);
	});
}

export function withOpenFiles(
	found: ProjectResults,
	keys: string[],
	openDoc: (key: string) => Document | null,
	q: Query,
): ProjectResults {
	const onDisk = new Map<string, Hit[]>();
	for (const f of found.files) { onDisk.set(f.key, f.hits); }
	const merged = gathered(keys, (key: string, room: int32): [Hit[], boolean] => {
		const open = openDoc(key);
		if (open !== null) { return hitsIn(open as Document, q, room); }
		const hits = onDisk.get(key);
		if (hits === undefined) { return [[], false]; }
		const all = hits as Hit[];
		return [all.slice(0, room), all.length > room];
	});
	return { ...merged, limitReached: merged.limitReached || found.limitReached };
}

export struct Located {
	key: string;
	hit: Hit;
	row: int32;
}

export function rowCount(r: ProjectResults): int32 {
	return (r.files.length as int32) + r.matches;
}

export function located(r: ProjectResults, k: int32): Located {
	let row = 0;
	let left = k;
	for (const f of r.files) {
		const n = f.hits.length as int32;
		if (left >= 0 && left < n) { return { key: f.key, hit: f.hits[left], row: row + 1 + left }; }
		left -= n;
		row += 1 + n;
	}
	throw new Error(`projectSearch: no hit ${k} among ${r.matches}`);
}

export function hitOfRow(r: ProjectResults, row: int32): int32 {
	let first = 0;
	let at = 0;
	for (const f of r.files) {
		const n = f.hits.length as int32;
		if (row >= at && row <= at + n) { return first + Math.max(0, row - at - 1); }
		at += 1 + n;
		first += n;
	}
	return -1;
}

export function stepped(r: ProjectResults, k: int32, forward: boolean): int32 {
	if (r.matches == 0) { return -1; }
	if (k < 0) { return forward ? 0 : r.matches - 1; }
	return (k + (forward ? 1 : r.matches - 1)) % r.matches;
}

function noOpen(key: string): Document | null { return null; }

function filesOf(texts: Map<string, string>): (key: string) => string | null {
	return (key: string): string | null => {
		const text = texts.get(key);
		return text === undefined ? null : text as string;
	};
}

test "results keep the given file order, one group per file with its hits by line" {
	const disk = new Map<string, string>();
	disk.set("b.ms", "let cat = 1;\nno\ncat(cat);\n");
	disk.set("a.ms", "nothing here\n");
	disk.set("c.ms", "\tcat\n");
	const r = searchProject(["b.ms", "a.ms", "c.ms", "gone.ms"], noOpen, filesOf(disk), { text: "cat", caseSensitive: true, wholeWord: false });
	assert r.files.length == 2 && r.files[0].key == "b.ms" && r.files[1].key == "c.ms";
	assert r.matches == 4 && !r.limitReached;
	const b = r.files[0].hits;
	assert b.length == 3;
	assert b[0].line == 0 && b[0].from == 4 && b[0].to == 7 && b[0].text == "let cat = 1;" && b[0].textFrom == 0;
	assert b[1].line == 2 && b[1].from == 0 && b[2].line == 2 && b[2].from == 4 && b[2].text == "cat(cat);";
	const c = r.files[1].hits[0];
	assert c.text == "cat" && c.textFrom == 1 && c.from == 1;
}

test "an open file is searched from its unsaved text, not from disk" {
	const disk = new Map<string, string>();
	disk.set("a.ms", "old needle\n");
	disk.set("b.ms", "needle on disk\n");
	const edited = new Document("first line\nthe needle moved\n");
	const open = (key: string): Document | null => key == "a.ms" ? edited : null;
	const r = searchProject(["a.ms", "b.ms"], open, filesOf(disk), { text: "needle", caseSensitive: true, wholeWord: false });
	assert r.files.length == 2 && r.files[0].hits[0].line == 1 && r.files[0].hits[0].text == "the needle moved";
	const fromDisk = searchProject(["a.ms", "b.ms"], noOpen, filesOf(disk), { text: "needle", caseSensitive: true, wholeWord: false });
	const merged = withOpenFiles(fromDisk, ["a.ms", "b.ms"], open, { text: "needle", caseSensitive: true, wholeWord: false });
	assert merged.files.length == 2 && merged.files[0].hits[0].line == 1 && merged.files[1].key == "b.ms";
	const gone = withOpenFiles(fromDisk, ["a.ms", "b.ms"], (key: string): Document | null => key == "b.ms" ? new Document("none") : null, { text: "needle", caseSensitive: true, wholeWord: false });
	assert gone.files.length == 1 && gone.files[0].key == "a.ms" && gone.files[0].hits[0].text == "old needle";
}

test "case and whole word follow the query" {
	const disk = new Map<string, string>();
	disk.set("a.ms", "Cat cat concat CAT\n");
	const keys = ["a.ms"];
	assert searchProject(keys, noOpen, filesOf(disk), { text: "cat", caseSensitive: false, wholeWord: false }).matches == 4;
	assert searchProject(keys, noOpen, filesOf(disk), { text: "cat", caseSensitive: true, wholeWord: false }).matches == 2;
	const words = searchProject(keys, noOpen, filesOf(disk), { text: "cat", caseSensitive: false, wholeWord: true });
	assert words.matches == 3 && words.files[0].hits[2].from == 15;
}

test "a hit on a non-ASCII line names bytes within the line" {
	const disk = new Map<string, string>();
	disk.set("v.ms", "x\n  const đích = \"đích\";\n");
	const r = searchProject(["v.ms"], noOpen, filesOf(disk), { text: "đích", caseSensitive: true, wholeWord: false });
	const hits = r.files[0].hits;
	assert hits.length == 2 && hits[0].line == 1 && hits[0].from == 8 && hits[0].to == 8 + "đích".byteLength;
	assert hits[0].textFrom == 2 && hits[0].text == "const đích = \"đích\";";
	assert hits[1].text.byteSlice(hits[1].from - hits[1].textFrom, hits[1].to - hits[1].textFrom) == "đích";
}

test "a long line is cut around its match on a character boundary" {
	const line = "ệ".repeat(200) + "needle" + "x".repeat(400);
	const hit = hitOn(0, line, 600, 606);
	assert hit.textFrom == 558 && hit.text.byteLength <= HIT_TEXT_BYTES;
	assert hit.text.byteSlice(hit.from - hit.textFrom, hit.to - hit.textFrom) == "needle";
	assert hitOn(0, "short needle", 6, 12).text == "short needle";
}

test "the search stops at the match limit and at the file limit" {
	const disk = new Map<string, string>();
	disk.set("many", "a ".repeat(MAX_RESULT_HITS - 1));
	disk.set("more", "a a a");
	disk.set("after", "a");
	const r = searchProject(["many", "more", "after"], noOpen, filesOf(disk), { text: "a", caseSensitive: true, wholeWord: false });
	assert r.limitReached && r.matches == MAX_RESULT_HITS && r.files.length == 2 && r.files[1].hits.length == 1;
	const keys: string[] = [];
	for (let i = 0; i <= MAX_RESULT_FILES; i++) { keys.push(`f${i}`); }
	const everywhere = searchProject(keys, noOpen, (key: string): string | null => "a", { text: "a", caseSensitive: true, wholeWord: false });
	assert everywhere.limitReached && everywhere.files.length == MAX_RESULT_FILES;
	const exact = new Map<string, string>();
	exact.set("one", "a");
	assert !searchProject(["one"], noOpen, filesOf(exact), { text: "a", caseSensitive: true, wholeWord: false }).limitReached;
}

test "a hit sits on the row after its file's row, and a file's row picks its first hit" {
	const disk = new Map<string, string>();
	disk.set("a", "x x");
	disk.set("b", "x");
	const r = searchProject(["a", "b"], noOpen, filesOf(disk), { text: "x", caseSensitive: true, wholeWord: false });
	assert rowCount(r) == 5;
	assert located(r, 0).row == 1 && located(r, 1).row == 2 && located(r, 2).row == 4 && located(r, 2).key == "b";
	assert hitOfRow(r, 0) == 0 && hitOfRow(r, 2) == 1 && hitOfRow(r, 3) == 2 && hitOfRow(r, 4) == 2 && hitOfRow(r, 5) == -1;
	assert stepped(r, 2, true) == 0 && stepped(r, 0, false) == 2 && stepped(r, -1, true) == 0 && stepped(r, -1, false) == 2;
	let refused = false;
	try { const _l = located(r, 3); } catch (e) { refused = true; }
	assert refused;
}

test "a file with a NUL byte near its start is taken as binary and skipped" {
	const disk = new Map<string, string>();
	disk.set("img", "PNG\u0000needle");
	disk.set("src", "needle");
	const r = searchProject(["img", "src"], noOpen, filesOf(disk), { text: "needle", caseSensitive: true, wholeWord: false });
	assert r.files.length == 1 && r.files[0].key == "src";
}
