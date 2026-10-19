import { Document } from "./document";

const NEWLINE: int32 = 10;
const ZWJ: int32 = 0x200D;
const CLUSTER_LOOKBACK: int32 = 32;

enum CharClass {
	Space,
	Newline,
	Word,
	Punct,
}

function isHigh(code: int32): boolean { return code >= 0xD800 && code <= 0xDBFF; }
function isLow(code: int32): boolean { return code >= 0xDC00 && code <= 0xDFFF; }

function codePointAt(doc: Document, at: int32): int32 {
	const code = doc.codeAt(at);
	if (isHigh(code) && at + 1 < doc.length()) {
		const low = doc.codeAt(at + 1);
		if (isLow(low)) { return 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00); }
	}
	return code;
}

function unitsOf(cp: int32): int32 { return cp >= 0x10000 ? 2 : 1; }

// Not full UAX #29: Hangul jamo, Indic conjuncts and regional-indicator flags split; widen this when one of them is typed.
function continuesCluster(cp: int32): boolean {
	return (cp >= 0x0300 && cp <= 0x036F) ||
		(cp >= 0x1AB0 && cp <= 0x1AFF) ||
		(cp >= 0x1DC0 && cp <= 0x1DFF) ||
		(cp >= 0x20D0 && cp <= 0x20FF) ||
		(cp >= 0xFE00 && cp <= 0xFE0F) ||
		(cp >= 0xFE20 && cp <= 0xFE2F) ||
		(cp >= 0x1F3FB && cp <= 0x1F3FF) ||
		(cp >= 0xE0020 && cp <= 0xE007F);
}

export function nextCluster(doc: Document, offset: int32): int32 {
	const total = doc.length();
	if (offset >= total) { return total; }
	let at = offset + unitsOf(codePointAt(doc, offset));
	while (at < total) {
		const cp = codePointAt(doc, at);
		if (cp == ZWJ) {
			at += 1;
			if (at < total) { at += unitsOf(codePointAt(doc, at)); }
		} else if (continuesCluster(cp)) {
			at += unitsOf(cp);
		} else {
			break;
		}
	}
	return at;
}

export function prevCluster(doc: Document, offset: int32): int32 {
	if (offset <= 0) { return 0; }
	if (doc.codeAt(offset - 1) == NEWLINE) { return offset - 1; }
	const lineStart = doc.lineStart(doc.lineOf(offset));
	let from = Math.max(lineStart, offset - CLUSTER_LOOKBACK);
	while (from > lineStart && !startsCluster(doc, from)) { from -= 1; }
	let last = from;
	let at = from;
	while (at < offset) {
		last = at;
		at = nextCluster(doc, at);
	}
	return last;
}

function startsCluster(doc: Document, at: int32): boolean {
	const code = doc.codeAt(at);
	if (isLow(code) || code == ZWJ || continuesCluster(codePointAt(doc, at))) { return false; }
	return at == 0 || doc.codeAt(at - 1) != ZWJ;
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
	if (at < total && classOf(doc.codeAt(at)) == CharClass.Newline) { return at + 1; }
	while (at < total && classOf(doc.codeAt(at)) == CharClass.Space) { at += 1; }
	if (at >= total || classOf(doc.codeAt(at)) == CharClass.Newline) { return at; }
	const run = classOf(doc.codeAt(at));
	while (at < total && classOf(doc.codeAt(at)) == run) { at += 1; }
	return at;
}

export function wordLeft(doc: Document, offset: int32): int32 {
	let at = offset;
	if (at > 0 && classOf(doc.codeAt(at - 1)) == CharClass.Newline) { return at - 1; }
	while (at > 0 && classOf(doc.codeAt(at - 1)) == CharClass.Space) { at -= 1; }
	if (at <= 0 || classOf(doc.codeAt(at - 1)) == CharClass.Newline) { return at; }
	const run = classOf(doc.codeAt(at - 1));
	while (at > 0 && classOf(doc.codeAt(at - 1)) == run) { at -= 1; }
	return at;
}

export function wordAt(doc: Document, offset: int32): int32[] {
	const total = doc.length();
	const probe = offset < total && classOf(doc.codeAt(offset)) != CharClass.Newline ? offset : offset - 1;
	if (probe < 0 || classOf(doc.codeAt(probe)) == CharClass.Newline) { return [offset, offset]; }
	const run = classOf(doc.codeAt(probe));
	let from = probe;
	let to = probe + 1;
	while (from > 0 && classOf(doc.codeAt(from - 1)) == run) { from -= 1; }
	while (to < total && classOf(doc.codeAt(to)) == run) { to += 1; }
	return [from, to];
}

export function columnOf(doc: Document, offset: int32): int32 {
	let at = doc.lineStart(doc.lineOf(offset));
	let column = 0;
	while (at < offset) {
		at = nextCluster(doc, at);
		column += 1;
	}
	return column;
}

export function offsetAtColumn(doc: Document, line: int32, column: int32): int32 {
	const end = doc.lineEnd(line);
	let at = doc.lineStart(line);
	for (let c = 0; c < column && at < end; c++) { at = nextCluster(doc, at); }
	return at;
}

export function indentEnd(doc: Document, line: int32): int32 {
	const end = doc.lineEnd(line);
	let at = doc.lineStart(line);
	while (at < end && classOf(doc.codeAt(at)) == CharClass.Space) { at += 1; }
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
	assert nextCluster(d, 1) == 3;
	assert nextCluster(d, 3) == 5;
	assert nextCluster(d, 5) == 10;
	assert nextCluster(d, 10) == 14;
	assert nextCluster(d, 14) == 15;
	assert prevCluster(d, 15) == 14;
	assert prevCluster(d, 14) == 10;
	assert prevCluster(d, 10) == 5;
	assert prevCluster(d, 5) == 3;
	assert prevCluster(d, 3) == 1;
}

test "a newline is its own cluster and ends the line's clusters" {
	const d = new Document("ab\ncd");
	assert prevCluster(d, 3) == 2;
	assert nextCluster(d, 2) == 3;
	assert prevCluster(d, 4) == 3;
}

test "a precomposed Vietnamese letter is one unit, a decomposed one is one cluster" {
	const d = new Document("tiếng tiếng");
	assert nextCluster(d, 2) == 3;
	assert columnOf(d, 5) == 5;
	assert nextCluster(d, 8) == 11;
	assert columnOf(d, 13) == 11;
}

test "word motion stops at word, punctuation and line edges" {
	const d = new Document("let x = foo.bar;\n  tiếng");
	assert wordRight(d, 0) == 3;
	assert wordRight(d, 3) == 5;
	assert wordRight(d, 9) == 11;
	assert wordRight(d, 11) == 12;
	assert wordRight(d, 16) == 17;
	assert wordRight(d, 17) == 24;
	assert wordLeft(d, 24) == 19;
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

test "columns count clusters and clamp at the line end" {
	const d = new Document("a😀b\nxy");
	assert columnOf(d, 3) == 2;
	assert offsetAtColumn(d, 0, 2) == 3;
	assert offsetAtColumn(d, 1, 9) == 7;
}

test "home goes to the indent, then to the line start" {
	const d = new Document("x\n\t  code");
	assert smartHome(d, 8) == 5;
	assert smartHome(d, 5) == 2;
	assert smartHome(d, 2) == 5;
}
