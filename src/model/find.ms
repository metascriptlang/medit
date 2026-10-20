import { Bias, Document, Edit } from "./document";
import { Editor, mapThrough } from "./editor";
import { Sel, end, single, span, start } from "./selection";

const WINDOW: int32 = 64 * 1024;

function isTrail(byte: int32): boolean { return (byte & 0xC0) == 0x80; }

function forwardToBoundary(this doc: Document, at: int32): int32 {
	let boundary = at;
	while (boundary < doc.length() && isTrail(doc.byteAt(boundary))) { boundary += 1; }
	return boundary;
}

function backToBoundary(this doc: Document, at: int32): int32 {
	let boundary = at;
	while (boundary > 0 && isTrail(doc.byteAt(boundary))) { boundary -= 1; }
	return boundary;
}

function refuseEmpty(needle: string): void {
	if (needle.byteLength == 0) { throw new Error("find: an empty needle matches everywhere"); }
}

function windowText(this doc: Document, from: int32, to: int32, needle: string): string {
	const reach = Math.min(doc.length(), to + needle.byteLength - 1);
	return doc.slice(from, doc.forwardToBoundary(reach));
}

function firstIn(this doc: Document, needle: string, from: int32, to: int32): int32 {
	let at = from;
	while (at < to) {
		const next = doc.forwardToBoundary(Math.min(to, at + WINDOW));
		const hit = doc.windowText(at, next, needle).byteIndexOf(needle);
		if (hit >= 0) { return at + hit < to ? at + hit : -1; }
		at = next;
	}
	return -1;
}

function lastIn(this doc: Document, needle: string, from: int32, to: int32): int32 {
	let top = to;
	while (top > from) {
		const low = Math.max(from, doc.backToBoundary(top - WINDOW));
		const hit = doc.windowText(low, top, needle).byteLastIndexOf(needle, top - low - 1);
		if (hit >= 0) { return low + hit; }
		top = low;
	}
	return -1;
}

export function nextMatch(this doc: Document, needle: string, from: int32): int32 {
	refuseEmpty(needle);
	const hit = doc.firstIn(needle, from, doc.length());
	return hit >= 0 ? hit : doc.firstIn(needle, 0, from);
}

export function prevMatch(this doc: Document, needle: string, before: int32): int32 {
	refuseEmpty(needle);
	const hit = doc.lastIn(needle, 0, before);
	return hit >= 0 ? hit : doc.lastIn(needle, before, doc.length());
}

export function allMatches(this doc: Document, needle: string): int32[] {
	refuseEmpty(needle);
	const n = needle.byteLength;
	const total = doc.length();
	const hits: int32[] = [];
	let at = 0;
	while (at + n <= total) {
		const next = doc.forwardToBoundary(Math.min(total, at + WINDOW));
		const text = doc.windowText(at, next, needle);
		let resume = next;
		let k = text.byteIndexOf(needle);
		while (k >= 0 && at + k < next) {
			hits.push(at + k);
			resume = Math.max(resume, at + k + n);
			k = text.byteIndexOf(needle, k + n);
		}
		at = resume;
	}
	return hits;
}

function primarySel(this e: Editor): Sel { return e.selections.ranges[e.selections.primary]; }

function selectAt(this e: Editor, needle: string, at: int32): boolean {
	if (at < 0) { return false; }
	e.select({ ranges: [span(at, at + needle.byteLength)], primary: 0 });
	return true;
}

export function selectMatch(this e: Editor, needle: string, backwards: boolean): boolean {
	const s = e.primarySel();
	const at = backwards ? e.doc.prevMatch(needle, s.start()) : e.doc.nextMatch(needle, s.end());
	return e.selectAt(needle, at);
}

export function selectFirstMatch(this e: Editor, needle: string): boolean {
	return e.selectAt(needle, e.doc.nextMatch(needle, e.primarySel().start()));
}

export function replaceMatch(this e: Editor, needle: string, replacement: string): boolean {
	const s = e.primarySel();
	if (e.selections.ranges.length == 1 && e.doc.slice(s.start(), s.end()) == needle) {
		e.replaceSelections(replacement);
	}
	return e.selectMatch(needle, false);
}

export function replaceAll(this e: Editor, needle: string, replacement: string): int32 {
	const hits = e.doc.allMatches(needle);
	if (hits.length == 0) { return 0; }
	const edits: Edit[] = [];
	for (const at of hits) {
		edits.push({ from: at, to: at + needle.byteLength, text: replacement });
	}
	e.begin();
	const applied = e.change(edits);
	e.select(single(mapThrough(e.primarySel().head, applied, Bias.Right)));
	e.end();
	return hits.length as int32;
}

test "a match that straddles a window is found from both directions" {
	const doc = new Document("x".repeat(WINDOW - 2) + "needle" + "x".repeat(10) + "needle");
	assert doc.nextMatch("needle", 0) == WINDOW - 2;
	assert doc.nextMatch("needle", WINDOW - 1) == WINDOW + 14;
	assert doc.prevMatch("needle", WINDOW + 14) == WINDOW - 2;
	assert doc.prevMatch("needle", doc.length()) == WINDOW + 14;
	assert doc.nextMatch("absent", 0) == -1;
	assert doc.prevMatch("absent", doc.length()) == -1;
}

test "a search wraps around the document" {
	const doc = new Document("one two one two");
	assert doc.nextMatch("one", 5) == 8;
	assert doc.nextMatch("one", 9) == 0;
	assert doc.prevMatch("two", 4) == 12;
	assert doc.prevMatch("two", 12) == 4;
}

test "a backward search takes the last match that starts before its point" {
	assert new Document("one two").prevMatch("two", 5) == 4;
	assert new Document("aaaa").prevMatch("aa", 4) == 2;
}

test "matches are found by byte past multi-byte text and window edges" {
	const filler = "ệ".repeat(30000);
	const doc = new Document(filler + "đích" + filler + "đích");
	const first = doc.nextMatch("đích", 0);
	assert first == 90000;
	assert doc.slice(first, first + "đích".byteLength) == "đích";
	assert doc.allMatches("đích").length == 2;
	assert doc.prevMatch("đích", doc.length()) == doc.length() - "đích".byteLength;
}

test "all matches do not overlap, across windows too" {
	const doc = new Document("aaaa");
	const hits = doc.allMatches("aa");
	assert hits.length == 2 && hits[0] == 0 && hits[1] == 2;
	const wide = new Document("x".repeat(WINDOW - 1) + "ab" + "x".repeat(WINDOW) + "ab");
	const far = wide.allMatches("ab");
	assert far.length == 2 && far[0] == WINDOW - 1 && far[1] == 2 * WINDOW + 1;
}

test "an empty needle is refused" {
	let refused = false;
	try { const _n = new Document("abc").nextMatch("", 0); } catch (e) { refused = true; }
	assert refused;
}

test "replace takes the selected match, then selects the next one" {
	const e = new Editor(new Document("cat dog cat"));
	assert e.selectMatch("cat", false);
	assert e.selections.ranges[0].start() == 0;
	assert e.replaceMatch("cat", "cow");
	assert e.doc.text() == "cow dog cat";
	assert e.selections.ranges[0].start() == 8 && e.selections.ranges[0].end() == 11;
	assert !e.replaceMatch("cat", "cow");
	assert e.doc.text() == "cow dog cow";
}

test "the first match counts from the selection start, so a growing needle keeps its place" {
	const e = new Editor(new Document("ab abc abcd"));
	e.select(single(1));
	assert e.selectFirstMatch("ab");
	assert e.selections.ranges[0].start() == 3;
	assert e.selectFirstMatch("abc");
	assert e.selections.ranges[0].start() == 3;
	assert e.selectFirstMatch("abcd");
	assert e.selections.ranges[0].start() == 7;
	assert !e.selectFirstMatch("abcde");
	assert e.selections.ranges[0].start() == 7;
}

test "replace all is one undo step" {
	const e = new Editor(new Document("a-b-c"));
	e.select(single(5));
	assert e.replaceAll("-", "--") == 2;
	assert e.doc.text() == "a--b--c";
	assert e.selections.ranges[0].head == 7;
	assert e.undo();
	assert e.doc.text() == "a-b-c";
	assert e.replaceAll("x", "y") == 0;
}
