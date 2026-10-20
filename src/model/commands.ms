import { Bias, Document, Edit } from "./document";
import { Editor, mapThrough } from "./editor";
import {
	columnOf,
	indentEnd,
	nextCluster,
	offsetAtColumn,
	prevCluster,
	smartHome,
	wordAt,
	wordLeft,
	wordRight,
} from "./motion";
import { Sel, cursorAt, single, span } from "./selection";
import { cellIn, offsetIn, rowIndexOf, rowsOf } from "../view/wrap";

const TAB: int32 = 9;
const SPACE: int32 = 32;
const OUTDENT_SPACES: int32 = 4;

export interface Clip {
	write: (text: string) => void;
	read: (done: (text: string) => void) => void;
}

export interface Context {
	pageRows: () => int32;
	wrapWidth: () => int32;
	toggleWrap: () => void;
	clip: Clip;
	save: (text: string) => void;
}

export type Command = (e: Editor, cx: Context) => void;

function moved(e: Editor, extend: boolean, target: (doc: Document, s: Sel) => int32): void {
	const next: Sel[] = [];
	for (const s of e.selections.ranges) {
		const head = target(e.doc, s);
		next.push(extend ? span(s.anchor, head) : cursorAt(head));
	}
	e.select({ ranges: next, primary: e.selections.primary });
}

function stepped(e: Editor, extend: boolean, toStart: boolean, by: (doc: Document, at: int32) => int32): void {
	moved(e, extend, (doc: Document, s: Sel): int32 => {
		if (!extend && !s.isEmpty()) { return toStart ? s.start() : s.end(); }
		return by(doc, s.head);
	});
}

function vertical(e: Editor, cx: Context, extend: boolean, rows: int32): void {
	const doc = e.doc;
	const width = cx.wrapWidth();
	const last = doc.lineCount() - 1;
	const next: Sel[] = [];
	for (const s of e.selections.ranges) {
		let line = doc.lineOf(s.head);
		let lineRows = rowsOf(doc, line, width);
		let k = rowIndexOf(lineRows, s.head);
		const goal = s.goal !== null ? s.goal as int32 : cellIn(doc, lineRows[k], s.head);
		k += rows;
		let head = -1;
		while (head < 0 && k < 0) {
			if (line == 0) { head = 0; }
			else {
				line -= 1;
				lineRows = rowsOf(doc, line, width);
				k += lineRows.length as int32;
			}
		}
		while (head < 0 && k >= (lineRows.length as int32)) {
			if (line == last) { head = doc.length(); }
			else {
				k -= lineRows.length as int32;
				line += 1;
				lineRows = rowsOf(doc, line, width);
			}
		}
		if (head < 0) { head = offsetIn(doc, lineRows[k], goal); }
		next.push({ anchor: extend ? s.anchor : head, head, goal });
	}
	e.select({ ranges: next, primary: e.selections.primary });
}

function linesOf(doc: Document, s: Sel): int32[] {
	const first = doc.lineOf(s.start());
	let last = doc.lineOf(s.end());
	if (last > first && doc.lineStart(last) == s.end()) { last -= 1; }
	return [first, last];
}

function touchedLines(e: Editor): int32[] {
	const lines: int32[] = [];
	for (const s of e.selections.ranges) {
		const range = linesOf(e.doc, s);
		for (let l = range[0]; l <= range[1]; l++) {
			if (lines.length == 0 || lines[lines.length - 1] < l) { lines.push(l); }
		}
	}
	return lines;
}

function rewriteLines(e: Editor, edits: Edit[]): void {
	if (edits.length == 0) { return; }
	e.begin();
	const applied = e.change(edits);
	const next: Sel[] = [];
	for (const s of e.selections.ranges) {
		const forward = s.anchor <= s.head;
		const start = mapThrough(s.start(), applied, Bias.Left);
		const end = mapThrough(s.end(), applied, s.isEmpty() ? Bias.Left : Bias.Right);
		next.push(forward ? span(start, end) : span(end, start));
	}
	e.select({ ranges: next, primary: e.selections.primary });
	e.end();
}

function deleteEach(e: Editor, group: string, range: (doc: Document, s: Sel) => int32[]): void {
	const edits: Edit[] = [];
	let lastTo = 0;
	for (const s of e.selections.ranges) {
		const r = s.isEmpty() ? range(e.doc, s) : [s.start(), s.end()];
		const from = Math.max(r[0], lastTo);
		const to = Math.max(r[1], from);
		edits.push({ from, to, text: "" });
		lastTo = to;
	}
	e.begin();
	e.groupAs(group);
	const applied = e.change(edits);
	const next: Sel[] = [];
	for (const c of applied) { next.push(cursorAt(c.from)); }
	e.select({ ranges: next, primary: e.selections.primary });
	e.end();
}

export function insertText(e: Editor, text: string): void {
	e.begin();
	if (text.indexOf("\n") < 0) { e.groupAs("type"); }
	e.replaceSelections(text);
	e.end();
}

function newline(e: Editor): void {
	const texts: string[] = [];
	for (const s of e.selections.ranges) {
		const line = e.doc.lineOf(s.start());
		const indent = Math.min(indentEnd(e.doc, line), s.start());
		texts.push("\n" + e.doc.slice(e.doc.lineStart(line), indent));
	}
	e.replaceEach(texts);
}

function indent(e: Editor): void {
	const edits: Edit[] = [];
	for (const l of touchedLines(e)) {
		const at = e.doc.lineStart(l);
		edits.push({ from: at, to: at, text: "\t" });
	}
	rewriteLines(e, edits);
}

function outdent(e: Editor): void {
	const edits: Edit[] = [];
	for (const l of touchedLines(e)) {
		const from = e.doc.lineStart(l);
		const end = e.doc.lineEnd(l);
		let to = from;
		if (from < end && e.doc.byteAt(from) == TAB) { to = from + 1; }
		else {
			while (to < end && to - from < OUTDENT_SPACES && e.doc.byteAt(to) == SPACE) { to += 1; }
		}
		if (to > from) { edits.push({ from, to, text: "" }); }
	}
	rewriteLines(e, edits);
}

function tab(e: Editor): void {
	for (const s of e.selections.ranges) {
		if (e.doc.lineOf(s.start()) != e.doc.lineOf(s.end())) {
			indent(e);
			return;
		}
	}
	insertText(e, "\t");
}

function wholeLine(doc: Document, s: Sel): int32[] {
	const line = doc.lineOf(s.head);
	const end = line + 1 < doc.lineCount() ? doc.lineStart(line + 1) : doc.length();
	return [doc.lineStart(line), end];
}

function allEmpty(e: Editor): boolean {
	for (const s of e.selections.ranges) { if (!s.isEmpty()) { return false; } }
	return true;
}

function copied(e: Editor): string {
	const lines = allEmpty(e);
	const parts: string[] = [];
	for (const s of e.selections.ranges) {
		if (lines) {
			const r = wholeLine(e.doc, s);
			const text = e.doc.slice(r[0], r[1]);
			parts.push(text.endsWith("\n") ? text.slice(0, text.length - 1) : text);
		} else {
			parts.push(e.doc.slice(s.start(), s.end()));
		}
	}
	const joined = parts.join("\n");
	return lines ? joined + "\n" : joined;
}

function copy(e: Editor, cx: Context): void {
	cx.clip.write(copied(e));
}

function cut(e: Editor, cx: Context): void {
	cx.clip.write(copied(e));
	if (allEmpty(e)) { deleteEach(e, "", wholeLine); }
	else { e.replaceSelections(""); }
}

export function paste(e: Editor, pasted: string): void {
	const text = pasted.replaceAll("\r\n", "\n");
	const parts = text.split("\n");
	const count = e.selections.ranges.length;
	if (count > 1 && parts.length == count) {
		e.replaceEach(parts);
		return;
	}
	if (count > 1 && parts.length == count + 1 && parts[count] == "") {
		e.replaceEach(parts.slice(0, count));
		return;
	}
	e.replaceSelections(text);
}

function addCursor(e: Editor, rows: int32): void {
	const ranges = e.selections.ranges;
	const from = rows < 0 ? ranges[0] : ranges[ranges.length - 1];
	const line = e.doc.lineOf(from.head) + rows;
	if (line < 0 || line >= e.doc.lineCount()) { return; }
	const goal = from.goal !== null ? from.goal as int32 : columnOf(e.doc, from.head);
	const head = offsetAtColumn(e.doc, line, goal);
	const next = ranges.slice(0, ranges.length);
	next.push({ anchor: head, head, goal });
	e.select({ ranges: next, primary: (next.length as int32) - 1 });
}

function selectNextOccurrence(e: Editor): void {
	const ranges = e.selections.ranges;
	const primary = ranges[e.selections.primary];
	if (primary.isEmpty()) {
		const w = wordAt(e.doc, primary.head);
		if (w[0] == w[1]) { return; }
		const next = ranges.slice(0, ranges.length);
		next[e.selections.primary] = span(w[0], w[1]);
		e.select({ ranges: next, primary: e.selections.primary });
		return;
	}
	const needle = e.doc.slice(primary.start(), primary.end());
	const all = e.doc.text();
	let at = all.byteIndexOf(needle, ranges[ranges.length - 1].end());
	if (at < 0) { at = all.byteIndexOf(needle); }
	for (const s of ranges) { if (s.start() == at) { return; } }
	const next = ranges.slice(0, ranges.length);
	next.push(span(at, at + needle.byteLength));
	e.select({ ranges: next, primary: (next.length as int32) - 1 });
}

function selectLine(e: Editor): void {
	const next: Sel[] = [];
	for (const s of e.selections.ranges) {
		const lines = linesOf(e.doc, s);
		const last = lines[1];
		const end = last + 1 < e.doc.lineCount() ? e.doc.lineStart(last + 1) : e.doc.length();
		next.push(span(e.doc.lineStart(lines[0]), end));
	}
	e.select({ ranges: next, primary: e.selections.primary });
}

function lineEndOf(doc: Document, s: Sel): int32 { return doc.lineEnd(doc.lineOf(s.head)); }
function homeOf(doc: Document, s: Sel): int32 { return smartHome(doc, s.head); }
function docStart(doc: Document, s: Sel): int32 { return 0; }
function docEnd(doc: Document, s: Sel): int32 { return doc.length(); }
function wordLeftOf(doc: Document, s: Sel): int32 { return wordLeft(doc, s.head); }
function wordRightOf(doc: Document, s: Sel): int32 { return wordRight(doc, s.head); }

export function commands(): Map<string, Command> {
	const m = new Map<string, Command>();
	m.set("left", (e: Editor, cx: Context): void => { stepped(e, false, true, prevCluster); });
	m.set("right", (e: Editor, cx: Context): void => { stepped(e, false, false, nextCluster); });
	m.set("selectLeft", (e: Editor, cx: Context): void => { stepped(e, true, true, prevCluster); });
	m.set("selectRight", (e: Editor, cx: Context): void => { stepped(e, true, false, nextCluster); });
	m.set("up", (e: Editor, cx: Context): void => { vertical(e, cx, false, -1); });
	m.set("down", (e: Editor, cx: Context): void => { vertical(e, cx, false, 1); });
	m.set("selectUp", (e: Editor, cx: Context): void => { vertical(e, cx, true, -1); });
	m.set("selectDown", (e: Editor, cx: Context): void => { vertical(e, cx, true, 1); });
	m.set("pageUp", (e: Editor, cx: Context): void => { vertical(e, cx, false, -cx.pageRows()); });
	m.set("pageDown", (e: Editor, cx: Context): void => { vertical(e, cx, false, cx.pageRows()); });
	m.set("selectPageUp", (e: Editor, cx: Context): void => { vertical(e, cx, true, -cx.pageRows()); });
	m.set("selectPageDown", (e: Editor, cx: Context): void => { vertical(e, cx, true, cx.pageRows()); });
	m.set("wordLeft", (e: Editor, cx: Context): void => { moved(e, false, wordLeftOf); });
	m.set("wordRight", (e: Editor, cx: Context): void => { moved(e, false, wordRightOf); });
	m.set("selectWordLeft", (e: Editor, cx: Context): void => { moved(e, true, wordLeftOf); });
	m.set("selectWordRight", (e: Editor, cx: Context): void => { moved(e, true, wordRightOf); });
	m.set("home", (e: Editor, cx: Context): void => { moved(e, false, homeOf); });
	m.set("end", (e: Editor, cx: Context): void => { moved(e, false, lineEndOf); });
	m.set("selectHome", (e: Editor, cx: Context): void => { moved(e, true, homeOf); });
	m.set("selectEnd", (e: Editor, cx: Context): void => { moved(e, true, lineEndOf); });
	m.set("docStart", (e: Editor, cx: Context): void => { moved(e, false, docStart); });
	m.set("docEnd", (e: Editor, cx: Context): void => { moved(e, false, docEnd); });
	m.set("selectDocStart", (e: Editor, cx: Context): void => { moved(e, true, docStart); });
	m.set("selectDocEnd", (e: Editor, cx: Context): void => { moved(e, true, docEnd); });
	m.set("selectAll", (e: Editor, cx: Context): void => {
		e.select({ ranges: [span(0, e.doc.length())], primary: 0 });
	});
	m.set("selectLine", (e: Editor, cx: Context): void => { selectLine(e); });
	m.set("selectNextOccurrence", (e: Editor, cx: Context): void => { selectNextOccurrence(e); });
	m.set("addCursorAbove", (e: Editor, cx: Context): void => { addCursor(e, -1); });
	m.set("addCursorBelow", (e: Editor, cx: Context): void => { addCursor(e, 1); });
	m.set("collapse", (e: Editor, cx: Context): void => {
		e.select(single(e.selections.ranges[e.selections.primary].head));
	});
	m.set("newline", (e: Editor, cx: Context): void => { newline(e); });
	m.set("tab", (e: Editor, cx: Context): void => { tab(e); });
	m.set("outdent", (e: Editor, cx: Context): void => { outdent(e); });
	m.set("backspace", (e: Editor, cx: Context): void => {
		deleteEach(e, "delete", (doc: Document, s: Sel): int32[] => [prevCluster(doc, s.head), s.head]);
	});
	m.set("delete", (e: Editor, cx: Context): void => {
		deleteEach(e, "delete", (doc: Document, s: Sel): int32[] => [s.head, nextCluster(doc, s.head)]);
	});
	m.set("deleteWordLeft", (e: Editor, cx: Context): void => {
		deleteEach(e, "", (doc: Document, s: Sel): int32[] => [wordLeft(doc, s.head), s.head]);
	});
	m.set("deleteWordRight", (e: Editor, cx: Context): void => {
		deleteEach(e, "", (doc: Document, s: Sel): int32[] => [s.head, wordRight(doc, s.head)]);
	});
	m.set("undo", (e: Editor, cx: Context): void => { const _u = e.undo(); });
	m.set("redo", (e: Editor, cx: Context): void => { const _r = e.redo(); });
	m.set("copy", copy);
	m.set("cut", cut);
	m.set("toggleWrap", (e: Editor, cx: Context): void => { cx.toggleWrap(); });
	m.set("save", (e: Editor, cx: Context): void => { cx.save(e.doc.fileText()); });
	m.set("paste", (e: Editor, cx: Context): void => {
		cx.clip.read((text: string): void => { paste(e, text); });
	});
	return m;
}

export struct Gesture {
	origin: Sel;
	clicks: int32;
}

function unitOf(doc: Document, offset: int32, clicks: int32): Sel {
	if (clicks == 2) {
		const w = wordAt(doc, offset);
		return span(w[0], w[1]);
	}
	if (clicks >= 3) {
		const line = wholeLine(doc, cursorAt(offset));
		return span(line[0], line[1]);
	}
	return cursorAt(offset);
}

export function press(e: Editor, offset: int32, clicks: int32, extend: boolean, add: boolean): Gesture {
	const ranges = e.selections.ranges;
	const primary = ranges[e.selections.primary];
	if (extend) {
		const next = ranges.slice(0, ranges.length);
		next[e.selections.primary] = span(primary.anchor, offset);
		e.select({ ranges: next, primary: e.selections.primary });
		return { origin: cursorAt(primary.anchor), clicks: 1 };
	}
	const unit = unitOf(e.doc, offset, clicks);
	if (add) {
		const next = ranges.slice(0, ranges.length);
		next.push(unit);
		e.select({ ranges: next, primary: (next.length as int32) - 1 });
	} else {
		e.select({ ranges: [unit], primary: 0 });
	}
	return { origin: unit, clicks };
}

export function drag(e: Editor, g: Gesture, offset: int32): void {
	const unit = unitOf(e.doc, offset, g.clicks);
	const forward = unit.end() >= g.origin.end();
	const dragged = forward ? span(g.origin.start(), unit.end()) : span(g.origin.end(), unit.start());
	const next = e.selections.ranges.slice(0, e.selections.ranges.length);
	next[e.selections.primary] = dragged;
	e.select({ ranges: next, primary: e.selections.primary });
}

function editorAt(text: string, offsets: int32[]): Editor {
	const e = new Editor(new Document(text));
	const ranges: Sel[] = [];
	for (const o of offsets) { ranges.push(cursorAt(o)); }
	e.select({ ranges, primary: 0 });
	return e;
}

function heads(e: Editor): string {
	const parts: string[] = [];
	for (const s of e.selections.ranges) { parts.push(s.anchor == s.head ? `${s.head}` : `${s.anchor}-${s.head}`); }
	return parts.join(",");
}

function runner(saved: string[] = []): (e: Editor, name: string) => void {
	const table = commands();
	let clipboard = "";
	let wrap = 0;
	const cx: Context = {
		pageRows: (): int32 => 2,
		wrapWidth: (): int32 => wrap,
		toggleWrap: (): void => { wrap = wrap == 0 ? 8 : 0; },
		clip: {
			write: (text: string): void => { clipboard = text; },
			read: (done: (text: string) => void): void => { done(clipboard); },
		},
		save: (text: string): void => { saved.push(text); },
	};
	return (e: Editor, name: string): void => {
		const c = table.get(name);
		if (c === undefined) { throw new Error(`no command ${name}`); }
		(c as Command)(e, cx);
	};
}

test "left and right step clusters and collapse a selection first" {
	const run = runner();
	const e = editorAt("a😀b", [1]);
	run(e, "right");
	assert heads(e) == "5";
	run(e, "selectLeft");
	assert heads(e) == "5-1";
	run(e, "right");
	assert heads(e) == "5";
}

test "up and down keep the goal column across a short line" {
	const run = runner();
	const e = editorAt("abcdef\nab\nabcdef", [5]);
	run(e, "down");
	assert heads(e) == "9";
	run(e, "down");
	assert heads(e) == "15";
	run(e, "up");
	run(e, "up");
	assert heads(e) == "5";
	run(e, "up");
	assert heads(e) == "0";
}

test "up and down move by wrapped rows and keep the cell within the row" {
	const run = runner();
	const e = editorAt("one two three four
ab", [2]);
	run(e, "toggleWrap");
	run(e, "down");
	assert heads(e) == "10";
	run(e, "down");
	assert heads(e) == "16";
	run(e, "down");
	assert heads(e) == "21";
	run(e, "up");
	run(e, "up");
	assert heads(e) == "10";
	run(e, "toggleWrap");
	run(e, "up");
	assert heads(e) == "0";
}

test "a newline keeps the indent before the cursor" {
	const run = runner();
	const e = editorAt("\t  code", [5]);
	run(e, "newline");
	assert e.doc.text() == "\t  co\n\t  de";
	assert heads(e) == "9";
}

test "backspace at several cursors deletes one cluster each and is one step" {
	const run = runner();
	const e = editorAt("a😀\nb😀", [5, 11]);
	run(e, "backspace");
	assert e.doc.text() == "a\nb";
	assert heads(e) == "1,3";
	run(e, "undo");
	assert e.doc.text() == "a😀\nb😀";
}

test "deleting words at cursors in one word merges into one cursor" {
	const run = runner();
	const e = editorAt("hello world", [2, 4]);
	run(e, "deleteWordLeft");
	assert e.doc.text() == "o world";
	assert heads(e) == "0";
}

test "tab over lines indents each line once and outdent takes it back" {
	const run = runner();
	const e = editorAt("a\nb\nc", [0]);
	e.select({ ranges: [span(0, 3)], primary: 0 });
	run(e, "tab");
	assert e.doc.text() == "\ta\n\tb\nc";
	assert heads(e) == "0-5";
	run(e, "outdent");
	assert e.doc.text() == "a\nb\nc";
}

test "copy with no selection takes the line and paste spreads lines over cursors" {
	const run = runner();
	const e = editorAt("one\ntwo", [1]);
	run(e, "copy");
	run(e, "docEnd");
	run(e, "newline");
	run(e, "paste");
	assert e.doc.text() == "one\ntwo\none\n";
	const m = editorAt("x\ny", [1, 3]);
	paste(m, "A\nB");
	assert m.doc.text() == "xA\nyB";
	const w = editorAt("x\ny", [1, 3]);
	paste(w, "A\r\nB\r\n");
	assert w.doc.text() == "xA\nyB";
	assert heads(w) == "2,5";
}

test "save hands over the file text with the line ending the file had" {
	const saved: string[] = [];
	const run = runner(saved);
	const e = editorAt("a
b", [1]);
	run(e, "newline");
	run(e, "save");
	assert saved.length == 1;
	assert saved[0] == "a

b";
}

test "typed letters undo as one word" {
	const run = runner();
	const e = editorAt("", [0]);
	insertText(e, "a");
	insertText(e, "b");
	run(e, "newline");
	insertText(e, "c");
	run(e, "undo");
	assert e.doc.text() == "ab\n";
	run(e, "undo");
	assert e.doc.text() == "ab";
	run(e, "undo");
	assert e.doc.text() == "";
}

test "next occurrence selects the word, then the next match, wrapping" {
	const run = runner();
	const e = editorAt("foo bar foo foo", [9]);
	run(e, "selectNextOccurrence");
	assert heads(e) == "8-11";
	run(e, "selectNextOccurrence");
	assert heads(e) == "8-11,12-15";
	run(e, "selectNextOccurrence");
	assert heads(e) == "0-3,8-11,12-15";
	assert e.selections.primary == 0;
}

test "a cursor added below lands at the same column" {
	const run = runner();
	const e = editorAt("abc\nabc\nab", [2]);
	run(e, "addCursorBelow");
	run(e, "addCursorBelow");
	assert heads(e) == "2,6,10";
	insertText(e, "!");
	assert e.doc.text() == "ab!c\nab!c\nab!";
}

test "a double-click drag selects whole words" {
	const e = editorAt("one two three", [0]);
	const g = press(e, 5, 2, false, false);
	assert heads(e) == "4-7";
	drag(e, g, 10);
	assert heads(e) == "4-13";
	drag(e, g, 1);
	assert heads(e) == "7-0";
}

test "alt-click adds a cursor and shift-click extends the primary" {
	const e = editorAt("abcdef", [1]);
	const _a = press(e, 4, 1, false, true);
	assert heads(e) == "1,4";
	assert e.selections.primary == 1;
	const _b = press(e, 6, 1, true, false);
	assert heads(e) == "1,4-6";
}
