import { Bias, Document, Edit } from "./document";
import { Editor, mapThrough } from "./editor";
import { isWordByte } from "./motion";
import { Sel, end, primaryRange, single, span, start } from "./selection";
import { isTrail } from "../text/clusters";

const WINDOW: int32 = 64 * 1024;
const UPPER_A: uint8 = 0x41;
const UPPER_Z: uint8 = 0x5a;
const TO_LOWER: uint8 = 0x20;

export struct Query {
	text: string;
	caseSensitive: boolean;
	wholeWord: boolean;
}

struct Pattern {
	needle: string;
	fold: boolean;
	wholeWord: boolean;
}

export function exact(text: string): Query {
	return { text, caseSensitive: true, wholeWord: false };
}

// Parked: non-ASCII letters match only their own case until std maps code points,
// ~/metascript/.inbox/compiler/2026-10-21-tolowercase-ascii-only.md
function asciiFolded(text: string): string {
	const bytes = text.asBytes();
	const out: uint8[] = [];
	for (let i = 0; i < bytes.length; i++) {
		const b = bytes[i];
		out.push(b >= UPPER_A && b <= UPPER_Z ? b + TO_LOWER : b);
	}
	return out.asString();
}

function patternOf(q: Query): Pattern {
	if (q.text.byteLength == 0) { throw new Error("find: an empty needle matches everywhere"); }
	const fold = !q.caseSensitive;
	return { needle: fold ? asciiFolded(q.text) : q.text, fold, wholeWord: q.wholeWord };
}

export function forwardToBoundary(this doc: Document, at: int32): int32 {
	let boundary = at;
	while (boundary < doc.length() && isTrail(doc.byteAt(boundary))) { boundary += 1; }
	return boundary;
}

export function backToBoundary(this doc: Document, at: int32): int32 {
	let boundary = at;
	while (boundary > 0 && isTrail(doc.byteAt(boundary))) { boundary -= 1; }
	return boundary;
}

function windowText(this doc: Document, from: int32, to: int32, p: Pattern): string {
	const reach = Math.min(doc.length(), to + p.needle.byteLength - 1);
	const text = doc.slice(from, doc.forwardToBoundary(reach));
	return p.fold ? asciiFolded(text) : text;
}

function isWordIn(this doc: Document, bytes: Readonly<Span<uint8>>, base: int32, at: int32): boolean {
	const k = at - base;
	if (k >= 0 && k < bytes.length) { return isWordByte(bytes[k] as int32); }
	return at >= 0 && at < doc.length() && isWordByte(doc.byteAt(at));
}

function accepts(
	this doc: Document,
	p: Pattern,
	bytes: Readonly<Span<uint8>>,
	base: int32,
	at: int32,
): boolean {
	if (!p.wholeWord) { return true; }
	const to = at + p.needle.byteLength;
	return !(doc.isWordIn(bytes, base, at) && doc.isWordIn(bytes, base, at - 1))
		&& !(doc.isWordIn(bytes, base, to - 1) && doc.isWordIn(bytes, base, to));
}

function firstIn(this doc: Document, p: Pattern, from: int32, to: int32): int32 {
	let at = from;
	while (at < to) {
		const next = doc.forwardToBoundary(Math.min(to, at + WINDOW));
		const text = doc.windowText(at, next, p);
		let hit = text.byteIndexOf(p.needle);
		while (hit >= 0 && at + hit < to) {
			if (doc.accepts(p, text.asBytes(), at, at + hit)) { return at + hit; }
			hit = text.byteIndexOf(p.needle, hit + 1);
		}
		at = next;
	}
	return -1;
}

function lastIn(this doc: Document, p: Pattern, from: int32, to: int32): int32 {
	let top = to;
	while (top > from) {
		const low = Math.max(from, doc.backToBoundary(top - WINDOW));
		const text = doc.windowText(low, top, p);
		let hit = text.byteLastIndexOf(p.needle, top - low - 1);
		while (hit >= 0) {
			if (doc.accepts(p, text.asBytes(), low, low + hit)) { return low + hit; }
			hit = hit > 0 ? text.byteLastIndexOf(p.needle, hit - 1) : -1;
		}
		top = low;
	}
	return -1;
}

export function nextMatch(this doc: Document, q: Query, from: int32): int32 {
	const p = patternOf(q);
	const hit = doc.firstIn(p, from, doc.length());
	return hit >= 0 ? hit : doc.firstIn(p, 0, from);
}

export function prevMatch(this doc: Document, q: Query, before: int32): int32 {
	const p = patternOf(q);
	const hit = doc.lastIn(p, 0, before);
	return hit >= 0 ? hit : doc.lastIn(p, before, doc.length());
}

export function matchesIn(this doc: Document, q: Query, from: int32, to: int32): int32[] {
	const p = patternOf(q);
	const n = p.needle.byteLength;
	const hits: int32[] = [];
	let at = from;
	while (at + n <= to) {
		const next = doc.forwardToBoundary(Math.min(to, at + WINDOW));
		const text = doc.windowText(at, next, p);
		let resume = next;
		let k = text.byteIndexOf(p.needle);
		while (k >= 0 && at + k < next) {
			if (doc.accepts(p, text.asBytes(), at, at + k)) {
				hits.push(at + k);
				resume = Math.max(resume, at + k + n);
				k = text.byteIndexOf(p.needle, k + n);
			} else {
				k = text.byteIndexOf(p.needle, k + 1);
			}
		}
		at = resume;
	}
	return hits;
}

export function allMatches(this doc: Document, q: Query): int32[] {
	return doc.matchesIn(q, 0, doc.length());
}

export function isMatchAt(this doc: Document, q: Query, from: int32, to: int32): boolean {
	const p = patternOf(q);
	if (to - from != p.needle.byteLength) { return false; }
	const text = doc.slice(from, to);
	return (p.fold ? asciiFolded(text) : text) == p.needle && doc.accepts(p, text.asBytes(), from, from);
}

function selectAt(this e: Editor, q: Query, at: int32): boolean {
	if (at < 0) { return false; }
	e.select({ ranges: [span(at, at + q.text.byteLength)], primary: 0 });
	return true;
}

export function selectMatch(this e: Editor, q: Query, backwards: boolean): boolean {
	const s = e.selections.primaryRange();
	const at = backwards ? e.doc.prevMatch(q, s.start()) : e.doc.nextMatch(q, s.end());
	return e.selectAt(q, at);
}

export function selectFirstMatch(this e: Editor, q: Query): boolean {
	return e.selectAt(q, e.doc.nextMatch(q, e.selections.primaryRange().start()));
}

export function selectAllMatches(this e: Editor, q: Query): int32 {
	const hits = e.doc.allMatches(q);
	if (hits.length == 0) { return 0; }
	const head = e.selections.primaryRange().start();
	const ranges: Sel[] = [];
	let primary = 0;
	for (const at of hits) {
		if (at < head) { primary = ranges.length + 1; }
		ranges.push(span(at, at + q.text.byteLength));
	}
	e.select({ ranges, primary: primary % ranges.length });
	return hits.length as int32;
}

export function replaceMatch(this e: Editor, q: Query, replacement: string): boolean {
	const s = e.selections.primaryRange();
	if (e.selections.ranges.length == 1 && e.doc.isMatchAt(q, s.start(), s.end())) {
		e.replaceSelections(replacement);
	}
	return e.selectMatch(q, false);
}

export function replaceAll(this e: Editor, q: Query, replacement: string): int32 {
	const hits = e.doc.allMatches(q);
	if (hits.length == 0) { return 0; }
	const edits: Edit[] = [];
	for (const at of hits) {
		edits.push({ from: at, to: at + q.text.byteLength, text: replacement });
	}
	e.begin();
	const applied = e.change(edits);
	e.select(single(mapThrough(e.selections.primaryRange().head, applied, Bias.Right)));
	e.end();
	return hits.length as int32;
}

test "a match that straddles a window is found from both directions" {
	const doc = new Document("x".repeat(WINDOW - 2) + "needle" + "x".repeat(10) + "needle");
	assert doc.nextMatch(exact("needle"), 0) == WINDOW - 2;
	assert doc.nextMatch(exact("needle"), WINDOW - 1) == WINDOW + 14;
	assert doc.prevMatch(exact("needle"), WINDOW + 14) == WINDOW - 2;
	assert doc.prevMatch(exact("needle"), doc.length()) == WINDOW + 14;
	assert doc.nextMatch(exact("absent"), 0) == -1;
	assert doc.prevMatch(exact("absent"), doc.length()) == -1;
}

test "a search wraps around the document" {
	const doc = new Document("one two one two");
	assert doc.nextMatch(exact("one"), 5) == 8;
	assert doc.nextMatch(exact("one"), 9) == 0;
	assert doc.prevMatch(exact("two"), 4) == 12;
	assert doc.prevMatch(exact("two"), 12) == 4;
}

test "a backward search takes the last match that starts before its point" {
	assert new Document("one two").prevMatch(exact("two"), 5) == 4;
	assert new Document("aaaa").prevMatch(exact("aa"), 4) == 2;
}

test "matches are found by byte past multi-byte text and window edges" {
	const filler = "ệ".repeat(30000);
	const doc = new Document(filler + "đích" + filler + "đích");
	const first = doc.nextMatch(exact("đích"), 0);
	assert first == 90000;
	assert doc.slice(first, first + "đích".byteLength) == "đích";
	assert doc.allMatches(exact("đích")).length == 2;
	assert doc.prevMatch(exact("đích"), doc.length()) == doc.length() - "đích".byteLength;
}

test "all matches do not overlap, across windows too" {
	const doc = new Document("aaaa");
	const hits = doc.allMatches(exact("aa"));
	assert hits.length == 2 && hits[0] == 0 && hits[1] == 2;
	const wide = new Document("x".repeat(WINDOW - 1) + "ab" + "x".repeat(WINDOW) + "ab");
	const far = wide.allMatches(exact("ab"));
	assert far.length == 2 && far[0] == WINDOW - 1 && far[1] == 2 * WINDOW + 1;
}

test "an empty needle is refused" {
	let refused = false;
	try { const _n = new Document("abc").nextMatch(exact(""), 0); } catch (e) { refused = true; }
	assert refused;
}

test "replace takes the selected match, then selects the next one" {
	const e = new Editor(new Document("cat dog cat"));
	assert e.selectMatch(exact("cat"), false);
	assert e.selections.ranges[0].start() == 0;
	assert e.replaceMatch(exact("cat"), "cow");
	assert e.doc.text() == "cow dog cat";
	assert e.selections.ranges[0].start() == 8 && e.selections.ranges[0].end() == 11;
	assert !e.replaceMatch(exact("cat"), "cow");
	assert e.doc.text() == "cow dog cow";
}

test "the first match counts from the selection start, so a growing needle keeps its place" {
	const e = new Editor(new Document("ab abc abcd"));
	e.select(single(1));
	assert e.selectFirstMatch(exact("ab"));
	assert e.selections.ranges[0].start() == 3;
	assert e.selectFirstMatch(exact("abc"));
	assert e.selections.ranges[0].start() == 3;
	assert e.selectFirstMatch(exact("abcd"));
	assert e.selections.ranges[0].start() == 7;
	assert !e.selectFirstMatch(exact("abcde"));
	assert e.selections.ranges[0].start() == 7;
}

test "replace all is one undo step" {
	const e = new Editor(new Document("a-b-c"));
	e.select(single(5));
	assert e.replaceAll(exact("-"), "--") == 2;
	assert e.doc.text() == "a--b--c";
	assert e.selections.ranges[0].head == 7;
	assert e.undo();
	assert e.doc.text() == "a-b-c";
	assert e.replaceAll(exact("x"), "y") == 0;
}

test "a search ignores ASCII case unless asked, keeping the match's own bytes" {
	const doc = new Document("Hello hello HELLO");
	const loose: Query = { text: "hELLo", caseSensitive: false, wholeWord: false };
	assert doc.allMatches(loose).length == 3;
	assert doc.nextMatch(loose, 1) == 6;
	assert doc.prevMatch(loose, 6) == 0;
	assert doc.allMatches(exact("hello")).length == 1;
	assert doc.isMatchAt(loose, 12, 17);
	assert !doc.isMatchAt(exact("hello"), 12, 17);
}

test "a whole-word search skips matches inside words and keeps looking" {
	const doc = new Document("cat concat cat_ (cat) cats ca");
	const word: Query = { text: "cat", caseSensitive: true, wholeWord: true };
	const hits = doc.allMatches(word);
	assert hits.length == 2 && hits[0] == 0 && hits[1] == 17;
	assert doc.nextMatch(word, 1) == 17;
	assert doc.prevMatch(word, 17) == 0;
	assert !doc.isMatchAt(word, 7, 10);
	const punct: Query = { text: "(cat", caseSensitive: true, wholeWord: true };
	assert doc.nextMatch(punct, 0) == 16;
	assert new Document("đcat cat").nextMatch(word, 0) == 6;
}

test "matches in a range start inside it and may end past it" {
	const doc = new Document("ab ab ab ab");
	const hits = doc.matchesIn(exact("ab"), 2, 7);
	assert hits.length == 2 && hits[0] == 3 && hits[1] == 6;
}

test "selecting all matches keeps the primary at the first one from the caret" {
	const e = new Editor(new Document("x y x y x"));
	e.select(single(3));
	assert e.selectAllMatches(exact("x")) == 3;
	assert e.selections.ranges.length == 3 && e.selections.primary == 1;
	e.select(single(9));
	assert e.selectAllMatches(exact("x")) == 3;
	assert e.selections.primary == 0;
	assert e.selectAllMatches(exact("z")) == 0;
	assert e.selections.ranges.length == 3;
}
