import { Document, Edit } from "./document";
import { Editor } from "./editor";
import { isWordByte } from "./motion";
import { Sel, cursorAt, end, isEmpty, single, span, start } from "./selection";

export struct Pair {
	open: string;
	close: string;
}

const PAIRS: Pair[] = [
	{ open: "(", close: ")" },
	{ open: "[", close: "]" },
	{ open: "{", close: "}" },
	{ open: "\"", close: "\"" },
	{ open: "'", close: "'" },
	{ open: "`", close: "`" },
];
const CLOSES_BEFORE = ";:.,=}])>";
const NEWLINE: int32 = "\n".code;

function opening(text: string): Pair | null {
	for (const p of PAIRS) { if (p.open == text) { return p; } }
	return null;
}

function closing(text: string): Pair | null {
	for (const p of PAIRS) { if (p.close == text) { return p; } }
	return null;
}

function closesBefore(doc: Document, at: int32): boolean {
	if (at >= doc.length()) { return true; }
	const next = doc.byteAt(at);
	return next == " ".code || next == "\t".code || next == "\r".code || next == NEWLINE
		|| CLOSES_BEFORE.includes(String.fromCharCode(next));
}

function opensQuoteAt(doc: Document, at: int32, quote: string): boolean {
	const from = doc.lineStart(doc.lineOf(at));
	if (at > from && isWordByte(doc.byteAt(at - 1))) { return false; }
	let count = 0;
	const q = quote.byteAt(0);
	for (let k = from; k < at; k++) { if (doc.byteAt(k) == q) { count += 1; } }
	return count % 2 == 0;
}

function autocloses(doc: Document, at: int32, p: Pair): boolean {
	if (!closesBefore(doc, at)) { return false; }
	return p.open != p.close || opensQuoteAt(doc, at, p.open);
}

export function typeText(e: Editor, text: string): void {
	const open = opening(text);
	const close = closing(text);
	const doc = e.doc;
	const edits: Edit[] = [];
	const next: Sel[] = [];
	const remembered: int32[] = [];
	let delta = 0;
	for (const s of e.selections.ranges) {
		const from = s.start();
		const to = s.end();
		if (!s.isEmpty() && open !== null) {
			const p = open as Pair;
			edits.push({ from, to: from, text: p.open });
			edits.push({ from: to, to, text: p.close });
			const shift = delta + p.open.byteLength;
			next.push(span(s.anchor + shift, s.head + shift));
			delta += p.open.byteLength + p.close.byteLength;
		} else if (s.isEmpty() && close !== null && e.isAutoclosedAt(s.head, (close as Pair).close)) {
			next.push(cursorAt(s.head + delta + text.byteLength));
		} else if (s.isEmpty() && open !== null && autocloses(doc, s.head, open as Pair)) {
			const p = open as Pair;
			edits.push({ from, to, text: p.open + p.close });
			const inside = s.head + delta + p.open.byteLength;
			next.push(cursorAt(inside));
			remembered.push(next.length as int32 - 1);
			delta += p.open.byteLength + p.close.byteLength;
		} else {
			edits.push({ from, to, text });
			next.push(cursorAt(from + delta + text.byteLength));
			delta += text.byteLength - (to - from);
		}
	}
	e.begin();
	e.groupAs("type");
	const _applied = e.change(edits);
	e.select({ ranges: next, primary: e.selections.primary });
	for (const k of remembered) {
		const p = open as Pair;
		e.rememberAutoclosed(next[k].head, p.open, p.close);
	}
	e.end();
}

export function pairAround(e: Editor, at: int32): Sel | null {
	for (const p of PAIRS) {
		if (e.isAutoclosedAt(at, p.close) && e.isAutoclosedFrom(at, p.open)) {
			return span(at - p.open.byteLength, at + p.close.byteLength);
		}
	}
	return null;
}

function typing(text: string, at: int32): Editor {
	const e = new Editor(new Document(text));
	e.select(single(at));
	return e;
}

test "an opener closes itself, and its closer is typed over" {
	const e = typing("a", 1);
	typeText(e, "(");
	assert e.doc.text() == "a()" && e.selections.ranges[0].head == 2;
	typeText(e, "x");
	assert e.doc.text() == "a(x)";
	typeText(e, ")");
	assert e.doc.text() == "a(x)" && e.selections.ranges[0].head == 4;
	typeText(e, ")");
	assert e.doc.text() == "a(x))";
}

test "an opener before a word stays alone" {
	const e = typing("ab", 0);
	typeText(e, "(");
	assert e.doc.text() == "(ab";
	const before = typing("x;", 1);
	typeText(before, "[");
	assert before.doc.text() == "x[];";
}

test "a quote after a word or closing an open quote stays alone" {
	const word = typing("don", 3);
	typeText(word, "'");
	assert word.doc.text() == "don'";
	const open = typing("\"a", 2);
	typeText(open, "\"");
	assert open.doc.text() == "\"a\"" && open.selections.ranges[0].head == 3;
	const fresh = typing("x = ", 4);
	typeText(fresh, "\"");
	assert fresh.doc.text() == "x = \"\"";
}

test "an opener typed over a selection wraps it" {
	const e = typing("ab cd", 0);
	e.select({ ranges: [span(3, 5)], primary: 0 });
	typeText(e, "[");
	assert e.doc.text() == "ab [cd]";
	assert e.selections.ranges[0].anchor == 4 && e.selections.ranges[0].head == 6;
}

test "a closer the editor did not insert, or left behind, is not typed over" {
	const e = typing("()", 1);
	typeText(e, ")");
	assert e.doc.text() == "())";
	const left = typing("", 0);
	typeText(left, "(");
	left.select(single(0));
	left.select(single(1));
	typeText(left, ")");
	assert left.doc.text() == "())";
}

test "a pair is around the caret only while nothing is typed inside it" {
	const e = typing("", 0);
	typeText(e, "{");
	const around = pairAround(e, 1);
	assert around !== null && (around as Sel).start() == 0 && (around as Sel).end() == 2;
	typeText(e, "x");
	assert pairAround(e, 2) === null;
}
