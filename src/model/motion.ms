import { Document } from "./document";

const NEWLINE: int32 = 10;
const ZWJ: int32 = 0x200D;
const CLUSTER_LOOKBACK: int32 = 64;

enum CharClass {
	Space,
	Newline,
	Word,
	Punct,
}

function isTrail(b: int32): boolean { return (b & 0xC0) == 0x80; }

function stepAt(doc: Document, at: int32): int32 {
	const lead = doc.byteAt(at);
	const n = lead < 0xC0 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4;
	return Math.min(n, doc.length() - at);
}

function codePointAt(doc: Document, at: int32): int32 {
	const lead = doc.byteAt(at);
	const n = stepAt(doc, at);
	if (n == 1) { return lead; }
	let cp = lead & (n == 2 ? 0x1F : n == 3 ? 0x0F : 0x07);
	for (let k = 1; k < n; k++) { cp = (cp << 6) | (doc.byteAt(at + k) & 0x3F); }
	return cp;
}

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
	let at = offset + stepAt(doc, offset);
	while (at < total) {
		const cp = codePointAt(doc, at);
		if (cp == ZWJ) {
			at += stepAt(doc, at);
			if (at < total) { at += stepAt(doc, at); }
		} else if (continuesCluster(cp)) {
			at += stepAt(doc, at);
		} else {
			break;
		}
	}
	return at;
}

export function prevCluster(doc: Document, offset: int32): int32 {
	if (offset <= 0) { return 0; }
	if (doc.byteAt(offset - 1) == NEWLINE) { return offset - 1; }
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
	if (isTrail(doc.byteAt(at))) { return false; }
	const cp = codePointAt(doc, at);
	if (cp == ZWJ || continuesCluster(cp)) { return false; }
	if (at == 0) { return true; }
	let prev = at - 1;
	while (prev > 0 && isTrail(doc.byteAt(prev))) { prev -= 1; }
	return codePointAt(doc, prev) != ZWJ;
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

test "columns count clusters and clamp at the line end" {
	const d = new Document("a😀b\nxy");
	assert columnOf(d, 5) == 2;
	assert offsetAtColumn(d, 0, 2) == 5;
	assert offsetAtColumn(d, 1, 9) == 9;
}

test "home goes to the indent, then to the line start" {
	const d = new Document("x\n\t  code");
	assert smartHome(d, 8) == 5;
	assert smartHome(d, 5) == 2;
	assert smartHome(d, 2) == 5;
}
