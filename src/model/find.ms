import { Bias, Document, Edit } from "./document";
import { Editor, mapThrough } from "./editor";
import { cursorAt, end, span, start } from "./selection";

const WINDOW: int32 = 64 * 1024;

function forwardToBoundary(doc: Document, at: int32): int32 {
	let b = at;
	while (b < doc.length() && (doc.byteAt(b) & 0xC0) == 0x80) { b += 1; }
	return b;
}

function backToBoundary(doc: Document, at: int32): int32 {
	let b = at;
	while (b > 0 && b < doc.length() && (doc.byteAt(b) & 0xC0) == 0x80) { b -= 1; }
	return b;
}

function checked(needle: string): int32 {
	if (needle.byteLength == 0) { throw new Error("find: an empty needle matches everywhere"); }
	return needle.byteLength as int32;
}

function firstIn(doc: Document, needle: string, from: int32, to: int32): int32 {
	const n = checked(needle);
	let at = from;
	while (at < to) {
		const next = forwardToBoundary(doc, Math.min(to, at + WINDOW));
		const stop = forwardToBoundary(doc, Math.min(doc.length(), next + n - 1));
		const hit = doc.slice(at, stop).byteIndexOf(needle);
		if (hit >= 0) { return at + hit < to ? at + hit : -1; }
		at = next;
	}
	return -1;
}

function lastIn(doc: Document, needle: string, from: int32, to: int32): int32 {
	const n = checked(needle);
	let top = to;
	while (top > from) {
		const low = Math.max(from, backToBoundary(doc, top - WINDOW));
		const text = doc.slice(low, forwardToBoundary(doc, Math.min(doc.length(), top + n - 1)));
		let last = -1;
		let k = text.byteIndexOf(needle);
		while (k >= 0 && low + k < top) {
			last = k;
			k = text.byteIndexOf(needle, k + 1);
		}
		if (last >= 0) { return low + last; }
		top = low;
	}
	return -1;
}

export function nextMatch(doc: Document, needle: string, from: int32): int32 {
	const hit = firstIn(doc, needle, from, doc.length());
	return hit >= 0 ? hit : firstIn(doc, needle, 0, from);
}

export function prevMatch(doc: Document, needle: string, before: int32): int32 {
	const hit = lastIn(doc, needle, 0, before);
	return hit >= 0 ? hit : lastIn(doc, needle, before, doc.length());
}

export function allMatches(doc: Document, needle: string): int32[] {
	const n = checked(needle);
	const total = doc.length();
	const out: int32[] = [];
	let at = 0;
	while (at + n <= total) {
		const next = forwardToBoundary(doc, Math.min(total, at + WINDOW));
		const text = doc.slice(at, forwardToBoundary(doc, Math.min(total, next + n - 1)));
		let resume = next;
		let k = text.byteIndexOf(needle);
		while (k >= 0 && at + k < next) {
			out.push(at + k);
			resume = Math.max(resume, at + k + n);
			k = text.byteIndexOf(needle, k + n);
		}
		at = resume;
	}
	return out;
}

export function selectMatch(e: Editor, needle: string, backwards: boolean): boolean {
	const s = e.selections.ranges[e.selections.primary];
	const at = backwards ? prevMatch(e.doc, needle, s.start()) : nextMatch(e.doc, needle, s.end());
	if (at < 0) { return false; }
	e.select({ ranges: [span(at, at + needle.byteLength)], primary: 0 });
	return true;
}

export function replaceMatch(e: Editor, needle: string, replacement: string): boolean {
	const s = e.selections.ranges[e.selections.primary];
	if (e.selections.ranges.length == 1 && e.doc.slice(s.start(), s.end()) == needle) {
		e.replaceSelections(replacement);
	}
	return selectMatch(e, needle, false);
}

export function replaceAll(e: Editor, needle: string, replacement: string): int32 {
	const hits = allMatches(e.doc, needle);
	if (hits.length == 0) { return 0; }
	const edits: Edit[] = [];
	for (const at of hits) { edits.push({ from: at, to: at + needle.byteLength, text: replacement }); }
	e.begin();
	const applied = e.change(edits);
	const head = mapThrough(e.selections.ranges[e.selections.primary].head, applied, Bias.Right);
	e.select({ ranges: [cursorAt(head)], primary: 0 });
	e.end();
	return hits.length as int32;
}

function padded(count: int32): string {
	const parts: string[] = [];
	for (let i = 0; i < count; i++) { parts.push("x"); }
	return parts.join("");
}

test "a match that straddles a window is found from both directions" {
	const doc = new Document(padded(WINDOW - 2) + "needle" + padded(10) + "needle");
	assert nextMatch(doc, "needle", 0) == WINDOW - 2;
	assert nextMatch(doc, "needle", WINDOW - 1) == WINDOW + 14;
	assert prevMatch(doc, "needle", WINDOW + 14) == WINDOW - 2;
	assert prevMatch(doc, "needle", doc.length()) == WINDOW + 14;
	assert nextMatch(doc, "absent", 0) == -1;
	assert prevMatch(doc, "absent", doc.length()) == -1;
}

test "a search wraps around the document" {
	const doc = new Document("one two one two");
	assert nextMatch(doc, "one", 5) == 8;
	assert nextMatch(doc, "one", 9) == 0;
	assert prevMatch(doc, "two", 4) == 12;
	assert prevMatch(doc, "two", 12) == 4;
}

test "matches are found by byte past multi-byte text and window edges" {
	const parts: string[] = [];
	for (let i = 0; i < 30000; i++) { parts.push("ệ"); }
	const doc = new Document(parts.join("") + "đích" + parts.join("") + "đích");
	const first = nextMatch(doc, "đích", 0);
	assert first == 90000;
	assert doc.slice(first, first + "đích".byteLength) == "đích";
	assert allMatches(doc, "đích").length == 2;
	assert prevMatch(doc, "đích", doc.length()) == doc.length() - "đích".byteLength;
}

test "all matches do not overlap, across windows too" {
	const doc = new Document("aaaa");
	const hits = allMatches(doc, "aa");
	assert hits.length == 2 && hits[0] == 0 && hits[1] == 2;
	const wide = new Document(padded(WINDOW - 1) + "ab" + padded(WINDOW) + "ab");
	const far = allMatches(wide, "ab");
	assert far.length == 2 && far[0] == WINDOW - 1 && far[1] == 2 * WINDOW + 1;
}

test "an empty needle is refused" {
	let refused = false;
	try { const _n = nextMatch(new Document("abc"), "", 0); } catch (e) { refused = true; }
	assert refused;
}

test "replace takes the selected match, then selects the next one" {
	const e = new Editor(new Document("cat dog cat"));
	assert selectMatch(e, "cat", false);
	assert e.selections.ranges[0].start() == 0;
	assert replaceMatch(e, "cat", "cow");
	assert e.doc.text() == "cow dog cat";
	assert e.selections.ranges[0].start() == 8 && e.selections.ranges[0].end() == 11;
	assert !replaceMatch(e, "cat", "cow");
	assert e.doc.text() == "cow dog cow";
}

test "replace all is one undo step" {
	const e = new Editor(new Document("a-b-c"));
	e.select({ ranges: [cursorAt(5)], primary: 0 });
	assert replaceAll(e, "-", "--") == 2;
	assert e.doc.text() == "a--b--c";
	assert e.selections.ranges[0].head == 7;
	assert e.undo();
	assert e.doc.text() == "a-b-c";
	assert replaceAll(e, "x", "y") == 0;
}
