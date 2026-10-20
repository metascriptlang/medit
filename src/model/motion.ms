import { Document } from "./document";
import { cellsIn, nextClusterIn, offsetAtCellIn, prevClusterIn } from "../text/clusters";

const NEWLINE: int32 = "\n".code;
const CLUSTER_LOOKBACK: int32 = 64;

enum CharClass {
	Space,
	Newline,
	Word,
	Punct,
}

export function nextCluster(this doc: Document, offset: int32): int32 {
	if (offset >= doc.length()) { return doc.length(); }
	if (doc.byteAt(offset) == NEWLINE) { return offset + 1; }
	const rest = doc.slice(offset, doc.lineEnd(doc.lineOf(offset)));
	return offset + nextClusterIn(rest.asBytes(), 0);
}

export function prevCluster(this doc: Document, offset: int32): int32 {
	if (offset <= 0) { return 0; }
	if (doc.byteAt(offset - 1) == NEWLINE) { return offset - 1; }
	const from = Math.max(doc.lineStart(doc.lineOf(offset)), offset - CLUSTER_LOOKBACK);
	const window = doc.slice(from, offset);
	return from + prevClusterIn(window.asBytes(), offset - from);
}

export function cellsBetween(this doc: Document, from: int32, to: int32, cell: int32): int32 {
	const text = doc.slice(from, to);
	return cellsIn(text.asBytes(), 0, to - from, cell);
}

export function offsetAtCell(
	this doc: Document,
	from: int32,
	to: int32,
	cell: int32,
	target: int32,
): int32 {
	const text = doc.slice(from, to);
	return from + offsetAtCellIn(text.asBytes(), 0, to - from, cell, target);
}

function classOf(code: int32): CharClass {
	return match (code) {
		NEWLINE => CharClass.Newline,
		" ".code | "\t".code | "\r".code => CharClass.Space,
		"_".code => CharClass.Word,
		_ when code >= "0".code && code <= "9".code => CharClass.Word,
		_ when code >= "A".code && code <= "Z".code => CharClass.Word,
		_ when code >= "a".code && code <= "z".code => CharClass.Word,
		_ when code >= 0x80 => CharClass.Word,
		_ => CharClass.Punct,
	};
}

function classAt(this doc: Document, at: int32): CharClass {
	return at >= 0 && at < doc.length() ? classOf(doc.byteAt(at)) : CharClass.Newline;
}

function skipRight(this doc: Document, from: int32, run: CharClass): int32 {
	let at = from;
	while (at < doc.length() && classOf(doc.byteAt(at)) == run) { at += 1; }
	return at;
}

function skipLeft(this doc: Document, from: int32, run: CharClass): int32 {
	let at = from;
	while (at > 0 && classOf(doc.byteAt(at - 1)) == run) { at -= 1; }
	return at;
}

export function wordRight(this doc: Document, offset: int32): int32 {
	if (offset < doc.length() && doc.classAt(offset) == CharClass.Newline) { return offset + 1; }
	const at = doc.skipRight(offset, CharClass.Space);
	const run = doc.classAt(at);
	return run == CharClass.Newline ? at : doc.skipRight(at, run);
}

export function wordLeft(this doc: Document, offset: int32): int32 {
	if (offset > 0 && doc.classAt(offset - 1) == CharClass.Newline) { return offset - 1; }
	const at = doc.skipLeft(offset, CharClass.Space);
	const run = doc.classAt(at - 1);
	return run == CharClass.Newline ? at : doc.skipLeft(at, run);
}

export function wordAt(this doc: Document, offset: int32): [int32, int32] {
	const probe = doc.classAt(offset) == CharClass.Newline ? offset - 1 : offset;
	const run = doc.classAt(probe);
	if (run == CharClass.Newline) { return [offset, offset]; }
	return [doc.skipLeft(probe, run), doc.skipRight(probe + 1, run)];
}

export function columnOf(this doc: Document, offset: int32): int32 {
	return doc.cellsBetween(doc.lineStart(doc.lineOf(offset)), offset, 0);
}

export function offsetAtColumn(this doc: Document, line: int32, column: int32): int32 {
	return doc.offsetAtCell(doc.lineStart(line), doc.lineEnd(line), 0, column);
}

export function indentEnd(this doc: Document, line: int32): int32 {
	return doc.skipRight(doc.lineStart(line), CharClass.Space);
}

export function smartHome(this doc: Document, offset: int32): int32 {
	const line = doc.lineOf(offset);
	const indent = doc.indentEnd(line);
	return offset == indent ? doc.lineStart(line) : indent;
}

test "a cluster holds a surrogate pair, its combining marks and a ZWJ sequence" {
	const d = new Document("a😀é👩‍💻👍🏽x");
	assert d.nextCluster(0) == 1;
	assert d.nextCluster(1) == 5;
	assert d.nextCluster(5) == 8;
	assert d.nextCluster(8) == 19;
	assert d.nextCluster(19) == 27;
	assert d.nextCluster(27) == 28;
	assert d.prevCluster(28) == 27;
	assert d.prevCluster(27) == 19;
	assert d.prevCluster(19) == 8;
	assert d.prevCluster(8) == 5;
	assert d.prevCluster(5) == 1;
}

test "a newline is its own cluster and ends the line's clusters" {
	const d = new Document("ab\ncd");
	assert d.prevCluster(3) == 2;
	assert d.nextCluster(2) == 3;
	assert d.prevCluster(4) == 3;
}

test "a precomposed Vietnamese letter is one code point, a decomposed one is one cluster" {
	const d = new Document("tiếng tiếng");
	assert d.nextCluster(2) == 5;
	assert d.columnOf(7) == 5;
	assert d.nextCluster(10) == 15;
	assert d.columnOf(17) == 11;
}

test "word motion stops at word, punctuation and line edges" {
	const d = new Document("let x = foo.bar;\n  tiếng");
	assert d.wordRight(0) == 3;
	assert d.wordRight(3) == 5;
	assert d.wordRight(9) == 11;
	assert d.wordRight(11) == 12;
	assert d.wordRight(16) == 17;
	assert d.wordRight(17) == 26;
	assert d.wordRight(26) == 26;
	assert d.wordLeft(26) == 19;
	assert d.wordLeft(19) == 17;
	assert d.wordLeft(17) == 16;
	assert d.wordLeft(16) == 15;
	assert d.wordLeft(3) == 0;
	assert d.wordLeft(0) == 0;
}

test "the word at an offset" {
	const d = new Document("foo.bar baz");
	const w = d.wordAt(5);
	assert w[0] == 4;
	assert w[1] == 7;
	const end = d.wordAt(11);
	assert end[0] == 8;
	assert end[1] == 11;
	const none = new Document("a\n\nb").wordAt(2);
	assert none[0] == 2 && none[1] == 2;
}

test "columns count display cells, a wide cluster two, and clamp at the line end" {
	const d = new Document("a😀b\nxy");
	assert d.columnOf(5) == 3;
	assert d.offsetAtColumn(0, 3) == 5;
	assert d.offsetAtColumn(0, 2) == 1;
	assert d.offsetAtColumn(1, 9) == 9;
	assert new Document("中文").columnOf(6) == 4;
}

test "a tab reaches the next tab stop of its line" {
	const d = new Document("ab\tx\n\t\tz");
	assert d.columnOf(3) == 4;
	assert d.columnOf(4) == 5;
	assert d.offsetAtColumn(0, 4) == 3;
	assert d.offsetAtColumn(0, 3) == 2;
	assert d.columnOf(7) == 8;
	assert d.cellsBetween(6, 7, 1) == 3;
}

test "home goes to the indent, then to the line start" {
	const d = new Document("x\n\t  code");
	assert d.smartHome(8) == 5;
	assert d.smartHome(5) == 2;
	assert d.smartHome(2) == 5;
}

test "the indent of a blank line ends at its line end" {
	const d = new Document(" \t\n  \n  ");
	assert d.indentEnd(0) == 2;
	assert d.indentEnd(1) == 5;
	assert d.indentEnd(2) == 8;
}
