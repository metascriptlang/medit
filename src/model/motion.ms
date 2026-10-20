import { Document } from "./document";
import { cellsIn, nextClusterIn, offsetAtCellIn, prevClusterIn } from "../text/clusters";

const NEWLINE: int32 = 10;
const CLUSTER_LOOKBACK: int32 = 64;

enum CharClass {
	Space,
	Newline,
	Word,
	Punct,
}

export function nextCluster(doc: Document, offset: int32): int32 {
	if (offset >= doc.length()) { return doc.length(); }
	if (doc.byteAt(offset) == NEWLINE) { return offset + 1; }
	const rest = doc.slice(offset, doc.lineEnd(doc.lineOf(offset)));
	return offset + nextClusterIn(rest.asBytes(), 0);
}

export function prevCluster(doc: Document, offset: int32): int32 {
	if (offset <= 0) { return 0; }
	if (doc.byteAt(offset - 1) == NEWLINE) { return offset - 1; }
	const from = Math.max(doc.lineStart(doc.lineOf(offset)), offset - CLUSTER_LOOKBACK);
	const window = doc.slice(from, offset);
	return from + prevClusterIn(window.asBytes(), offset - from);
}

export function cellsBetween(doc: Document, from: int32, to: int32, cell: int32): int32 {
	const text = doc.slice(from, to);
	return cellsIn(text.asBytes(), 0, to - from, cell);
}

export function offsetAtCell(doc: Document, from: int32, to: int32, cell: int32, target: int32): int32 {
	const text = doc.slice(from, to);
	return from + offsetAtCellIn(text.asBytes(), 0, to - from, cell, target);
}

function classOf(code: int32): CharClass {
	if (code == NEWLINE) { return CharClass.Newline; }
	if (code == 32 || code == 9 || code == 13) { return CharClass.Space; }
	const alnum = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
	return alnum || code == 95 || code >= 0x80 ? CharClass.Word : CharClass.Punct;
}

export function wordRight(doc: Document, offset: int32): int32 {
	const total = doc.length();
	let at = offset;
	if (at < total && classOf(doc.byteAt(at)) == CharClass.Newline) { return at + 1; }
	while (at < total && classOf(doc.byteAt(at)) == CharClass.Space) { at += 1; }
	if (at >= total || classOf(doc.byteAt(at)) == CharClass.Newline) { return at; }
	const run = classOf(doc.byteAt(at));
	while (at < total && classOf(doc.byteAt(at)) == run) { at += 1; }
	return at;
}

export function wordLeft(doc: Document, offset: int32): int32 {
	let at = offset;
	if (at > 0 && classOf(doc.byteAt(at - 1)) == CharClass.Newline) { return at - 1; }
	while (at > 0 && classOf(doc.byteAt(at - 1)) == CharClass.Space) { at -= 1; }
	if (at <= 0 || classOf(doc.byteAt(at - 1)) == CharClass.Newline) { return at; }
	const run = classOf(doc.byteAt(at - 1));
	while (at > 0 && classOf(doc.byteAt(at - 1)) == run) { at -= 1; }
	return at;
}

export function wordAt(doc: Document, offset: int32): int32[] {
	const total = doc.length();
	const probe = offset < total && classOf(doc.byteAt(offset)) != CharClass.Newline ? offset : offset - 1;
	if (probe < 0 || classOf(doc.byteAt(probe)) == CharClass.Newline) { return [offset, offset]; }
	const run = classOf(doc.byteAt(probe));
	let from = probe;
	let to = probe + 1;
	while (from > 0 && classOf(doc.byteAt(from - 1)) == run) { from -= 1; }
	while (to < total && classOf(doc.byteAt(to)) == run) { to += 1; }
	return [from, to];
}

export function columnOf(doc: Document, offset: int32): int32 {
	return cellsBetween(doc, doc.lineStart(doc.lineOf(offset)), offset, 0);
}

export function offsetAtColumn(doc: Document, line: int32, column: int32): int32 {
	return offsetAtCell(doc, doc.lineStart(line), doc.lineEnd(line), 0, column);
}

export function indentEnd(doc: Document, line: int32): int32 {
	const end = doc.lineEnd(line);
	let at = doc.lineStart(line);
	while (at < end && classOf(doc.byteAt(at)) == CharClass.Space) { at += 1; }
	return at;
}

export function smartHome(doc: Document, offset: int32): int32 {
	const line = doc.lineOf(offset);
	const indent = indentEnd(doc, line);
	return offset == indent ? doc.lineStart(line) : indent;
}

test "a cluster holds a surrogate pair, its combining marks and a ZWJ sequence" {
	const d = new Document("a😀é👩‍💻👍🏽x");
	assert nextCluster(d, 0) == 1;
	assert nextCluster(d, 1) == 5;
	assert nextCluster(d, 5) == 8;
	assert nextCluster(d, 8) == 19;
	assert nextCluster(d, 19) == 27;
	assert nextCluster(d, 27) == 28;
	assert prevCluster(d, 28) == 27;
	assert prevCluster(d, 27) == 19;
	assert prevCluster(d, 19) == 8;
	assert prevCluster(d, 8) == 5;
	assert prevCluster(d, 5) == 1;
}

test "a newline is its own cluster and ends the line's clusters" {
	const d = new Document("ab\ncd");
	assert prevCluster(d, 3) == 2;
	assert nextCluster(d, 2) == 3;
	assert prevCluster(d, 4) == 3;
}

test "a precomposed Vietnamese letter is one code point, a decomposed one is one cluster" {
	const d = new Document("tiếng tiếng");
	assert nextCluster(d, 2) == 5;
	assert columnOf(d, 7) == 5;
	assert nextCluster(d, 10) == 15;
	assert columnOf(d, 17) == 11;
}

test "word motion stops at word, punctuation and line edges" {
	const d = new Document("let x = foo.bar;\n  tiếng");
	assert wordRight(d, 0) == 3;
	assert wordRight(d, 3) == 5;
	assert wordRight(d, 9) == 11;
	assert wordRight(d, 11) == 12;
	assert wordRight(d, 16) == 17;
	assert wordRight(d, 17) == 26;
	assert wordLeft(d, 26) == 19;
	assert wordLeft(d, 19) == 17;
	assert wordLeft(d, 17) == 16;
	assert wordLeft(d, 16) == 15;
}

test "the word at an offset" {
	const d = new Document("foo.bar baz");
	const w = wordAt(d, 5);
	assert w[0] == 4;
	assert w[1] == 7;
	const end = wordAt(d, 11);
	assert end[0] == 8;
	assert end[1] == 11;
}

test "columns count display cells, a wide cluster two, and clamp at the line end" {
	const d = new Document("a😀b\nxy");
	assert columnOf(d, 5) == 3;
	assert offsetAtColumn(d, 0, 3) == 5;
	assert offsetAtColumn(d, 0, 2) == 1;
	assert offsetAtColumn(d, 1, 9) == 9;
	assert columnOf(new Document("中文"), 6) == 4;
}

test "a tab reaches the next tab stop of its line" {
	const d = new Document("ab\tx\n\t\tz");
	assert columnOf(d, 3) == 4;
	assert columnOf(d, 4) == 5;
	assert offsetAtColumn(d, 0, 4) == 3;
	assert offsetAtColumn(d, 0, 3) == 2;
	assert columnOf(d, 7) == 8;
	assert cellsBetween(d, 6, 7, 1) == 3;
}

test "home goes to the indent, then to the line start" {
	const d = new Document("x\n\t  code");
	assert smartHome(d, 8) == 5;
	assert smartHome(d, 5) == 2;
	assert smartHome(d, 2) == 5;
}
