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
import { nextMatch } from "./find";
import { cellIn, offsetIn, rowIndexOf, rowsOf } from "../view/wrap";

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
	findBar: (replace: boolean) => void;
	findAgain: (backwards: boolean) => void;
}

export type Command = (e: Editor, cx: Context) => void;

type Motion = (e: Editor, cx: Context, extend: boolean) => void;
type Target = (doc: Document, at: int32) => int32;

function reselect(e: Editor, each: (s: Sel) => Sel): void {
	const next: Sel[] = [];
	for (const s of e.selections.ranges) { next.push(each(s)); }
	e.select({ ranges: next, primary: e.selections.primary });
}

function replacePrimary(e: Editor, s: Sel): void {
	const next = e.selections.ranges.slice(0, e.selections.ranges.length);
	next[e.selections.primary] = s;
	e.select({ ranges: next, primary: e.selections.primary });
}

function addPrimary(e: Editor, s: Sel): void {
	const next = e.selections.ranges.slice(0, e.selections.ranges.length);
	next.push(s);
	e.select({ ranges: next, primary: (next.length as int32) - 1 });
}

function moved(e: Editor, extend: boolean, target: (doc: Document, s: Sel) => int32): void {
	reselect(e, (s: Sel): Sel => {
		const head = target(e.doc, s);
		return extend ? span(s.anchor, head) : cursorAt(head);
	});
}

function jump(to: Target): Motion {
	return (e: Editor, cx: Context, extend: boolean): void => {
		moved(e, extend, (doc: Document, s: Sel): int32 => to(doc, s.head));
	};
}

function step(by: Target, toStart: boolean): Motion {
	return (e: Editor, cx: Context, extend: boolean): void => {
		moved(e, extend, (doc: Document, s: Sel): int32 => {
			if (!extend && !s.isEmpty()) { return toStart ? s.start() : s.end(); }
			return by(doc, s.head);
		});
	};
}

function byRows(rows: int32): Motion {
	return (e: Editor, cx: Context, extend: boolean): void => { vertical(e, cx, extend, rows); };
}

function byPages(pages: int32): Motion {
	return (e: Editor, cx: Context, extend: boolean): void => {
		vertical(e, cx, extend, pages * cx.pageRows());
	};
}

function lineEndAt(doc: Document, at: int32): int32 { return doc.lineEnd(doc.lineOf(at)); }
function docStart(doc: Document, at: int32): int32 { return 0; }
function docEnd(doc: Document, at: int32): int32 { return doc.length(); }

function vertical(e: Editor, cx: Context, extend: boolean, rows: int32): void {
	const doc = e.doc;
	const width = cx.wrapWidth();
	const last = doc.lineCount() - 1;
	reselect(e, (s: Sel): Sel => {
		let line = doc.lineOf(s.head);
		let lineRows = rowsOf(doc, line, width);
		let row = rowIndexOf(lineRows, s.head);
		const goal = s.goal !== null ? s.goal as int32 : cellIn(doc, lineRows[row], s.head);
		row += rows;
		while (row < 0 && line > 0) {
			line -= 1;
			lineRows = rowsOf(doc, line, width);
			row += lineRows.length as int32;
		}
		while (row >= (lineRows.length as int32) && line < last) {
			row -= lineRows.length as int32;
			line += 1;
			lineRows = rowsOf(doc, line, width);
		}
		let head = 0;
		if (row >= (lineRows.length as int32)) { head = doc.length(); }
		else if (row >= 0) { head = offsetIn(doc, lineRows[row], goal); }
		return { anchor: extend ? s.anchor : head, head, goal };
	});
}

function linesOf(doc: Document, s: Sel): [int32, int32] {
	const first = doc.lineOf(s.start());
	let last = doc.lineOf(s.end());
	if (last > first && doc.lineStart(last) == s.end()) { last -= 1; }
	return [first, last];
}

function afterLine(doc: Document, line: int32): int32 {
	return line + 1 < doc.lineCount() ? doc.lineStart(line + 1) : doc.length();
}

function lineSpan(doc: Document, at: int32): Sel {
	const line = doc.lineOf(at);
	return span(doc.lineStart(line), afterLine(doc, line));
}

function wordSpan(doc: Document, at: int32): Sel {
	const [from, to] = wordAt(doc, at);
	return span(from, to);
}

function touchedLines(e: Editor): int32[] {
	const lines: int32[] = [];
	for (const s of e.selections.ranges) {
		const [first, last] = linesOf(e.doc, s);
		for (let line = first; line <= last; line++) {
			if (lines.length == 0 || lines[lines.length - 1] < line) { lines.push(line); }
		}
	}
	return lines;
}

function rewriteLines(e: Editor, edits: Edit[]): void {
	if (edits.length == 0) { return; }
	e.begin();
	const applied = e.change(edits);
	reselect(e, (s: Sel): Sel => {
		const start = mapThrough(s.start(), applied, Bias.Left);
		const end = mapThrough(s.end(), applied, s.isEmpty() ? Bias.Left : Bias.Right);
		return s.anchor <= s.head ? span(start, end) : span(end, start);
	});
	e.end();
}

function deleteEach(e: Editor, group: string, around: (doc: Document, at: int32) => Sel): void {
	const edits: Edit[] = [];
	let lastTo = 0;
	for (const s of e.selections.ranges) {
		const range = s.isEmpty() ? around(e.doc, s.head) : s;
		const from = Math.max(range.start(), lastTo);
		const to = Math.max(range.end(), from);
		edits.push({ from, to, text: "" });
		lastTo = to;
	}
	e.begin();
	e.groupAs(group);
	const applied = e.change(edits);
	const next: Sel[] = [];
	for (const change of applied) { next.push(cursorAt(change.from)); }
	e.select({ ranges: next, primary: e.selections.primary });
	e.end();
}

function deleteToward(group: string, by: Target): Command {
	return (e: Editor, cx: Context): void => {
		deleteEach(e, group, (doc: Document, at: int32): Sel => span(at, by(doc, at)));
	};
}

export function insertText(e: Editor, text: string): void {
	e.begin();
	if (text.indexOf("\n") < 0) { e.groupAs("type"); }
	e.replaceSelections(text);
	e.end();
}

function newline(e: Editor, cx: Context): void {
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

function outdentTo(doc: Document, line: int32): int32 {
	const from = doc.lineStart(line);
	const end = doc.lineEnd(line);
	if (from < end && doc.byteAt(from) == "\t".code) { return from + 1; }
	const limit = Math.min(end, from + OUTDENT_SPACES);
	let to = from;
	while (to < limit && doc.byteAt(to) == " ".code) { to += 1; }
	return to;
}

function outdent(e: Editor, cx: Context): void {
	const edits: Edit[] = [];
	for (const line of touchedLines(e)) {
		const from = e.doc.lineStart(line);
		const to = outdentTo(e.doc, line);
		if (to > from) { edits.push({ from, to, text: "" }); }
	}
	rewriteLines(e, edits);
}

function tab(e: Editor, cx: Context): void {
	for (const s of e.selections.ranges) {
		if (e.doc.lineOf(s.start()) != e.doc.lineOf(s.end())) {
			indent(e);
			return;
		}
	}
	insertText(e, "\t");
}

function allEmpty(e: Editor): boolean {
	for (const s of e.selections.ranges) { if (!s.isEmpty()) { return false; } }
	return true;
}

function copied(e: Editor): string {
	const wholeLines = allEmpty(e);
	const parts: string[] = [];
	for (const s of e.selections.ranges) {
		parts.push(wholeLines ? e.doc.line(e.doc.lineOf(s.head)) : e.doc.slice(s.start(), s.end()));
	}
	const joined = parts.join("\n");
	return wholeLines ? joined + "\n" : joined;
}

function copy(e: Editor, cx: Context): void {
	cx.clip.write(copied(e));
}

function cut(e: Editor, cx: Context): void {
	cx.clip.write(copied(e));
	if (allEmpty(e)) { deleteEach(e, "", lineSpan); }
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
	addPrimary(e, { anchor: head, head, goal });
}

function selectNextOccurrence(e: Editor, cx: Context): void {
	const ranges = e.selections.ranges;
	const primary = ranges[e.selections.primary];
	if (primary.isEmpty()) {
		const word = wordSpan(e.doc, primary.head);
		if (!word.isEmpty()) { replacePrimary(e, word); }
		return;
	}
	const needle = e.doc.slice(primary.start(), primary.end());
	const at = nextMatch(e.doc, needle, ranges[ranges.length - 1].end());
	if (ranges.some((s: Sel): boolean => s.start() == at)) { return; }
	addPrimary(e, span(at, at + needle.byteLength));
}

function selectLine(e: Editor, cx: Context): void {
	reselect(e, (s: Sel): Sel => {
		const [first, last] = linesOf(e.doc, s);
		return span(e.doc.lineStart(first), afterLine(e.doc, last));
	});
}

export function commands(): Map<string, Command> {
	const table = new Map<string, Command>();
	const addMotion = (name: string, selectName: string, motion: Motion): void => {
		table.set(name, (e: Editor, cx: Context): void => { motion(e, cx, false); });
		table.set(selectName, (e: Editor, cx: Context): void => { motion(e, cx, true); });
	};
	addMotion("left", "selectLeft", step(prevCluster, true));
	addMotion("right", "selectRight", step(nextCluster, false));
	addMotion("up", "selectUp", byRows(-1));
	addMotion("down", "selectDown", byRows(1));
	addMotion("pageUp", "selectPageUp", byPages(-1));
	addMotion("pageDown", "selectPageDown", byPages(1));
	addMotion("wordLeft", "selectWordLeft", jump(wordLeft));
	addMotion("wordRight", "selectWordRight", jump(wordRight));
	addMotion("home", "selectHome", jump(smartHome));
	addMotion("end", "selectEnd", jump(lineEndAt));
	addMotion("docStart", "selectDocStart", jump(docStart));
	addMotion("docEnd", "selectDocEnd", jump(docEnd));
	table.set("selectAll", (e: Editor, cx: Context): void => {
		e.select({ ranges: [span(0, e.doc.length())], primary: 0 });
	});
	table.set("selectLine", selectLine);
	table.set("selectNextOccurrence", selectNextOccurrence);
	table.set("addCursorAbove", (e: Editor, cx: Context): void => { addCursor(e, -1); });
	table.set("addCursorBelow", (e: Editor, cx: Context): void => { addCursor(e, 1); });
	table.set("collapse", (e: Editor, cx: Context): void => {
		e.select(single(e.selections.ranges[e.selections.primary].head));
	});
	table.set("newline", newline);
	table.set("tab", tab);
	table.set("outdent", outdent);
	table.set("backspace", deleteToward("delete", prevCluster));
	table.set("delete", deleteToward("delete", nextCluster));
	table.set("deleteWordLeft", deleteToward("", wordLeft));
	table.set("deleteWordRight", deleteToward("", wordRight));
	table.set("undo", (e: Editor, cx: Context): void => { e.undo(); });
	table.set("redo", (e: Editor, cx: Context): void => { e.redo(); });
	table.set("copy", copy);
	table.set("cut", cut);
	table.set("toggleWrap", (e: Editor, cx: Context): void => { cx.toggleWrap(); });
	table.set("save", (e: Editor, cx: Context): void => { cx.save(e.doc.fileText()); });
	table.set("find", (e: Editor, cx: Context): void => { cx.findBar(false); });
	table.set("replace", (e: Editor, cx: Context): void => { cx.findBar(true); });
	table.set("findNext", (e: Editor, cx: Context): void => { cx.findAgain(false); });
	table.set("findPrev", (e: Editor, cx: Context): void => { cx.findAgain(true); });
	table.set("paste", (e: Editor, cx: Context): void => {
		cx.clip.read((text: string): void => { paste(e, text); });
	});
	return table;
}

export struct Gesture {
	origin: Sel;
	clicks: int32;
}

function unitOf(doc: Document, offset: int32, clicks: int32): Sel {
	return match (clicks) {
		2 => wordSpan(doc, offset),
		_ when clicks >= 3 => lineSpan(doc, offset),
		_ => cursorAt(offset),
	};
}

export function press(
	e: Editor,
	offset: int32,
	clicks: int32,
	extend: boolean,
	add: boolean,
): Gesture {
	const anchor = e.selections.ranges[e.selections.primary].anchor;
	if (extend) {
		replacePrimary(e, span(anchor, offset));
		return { origin: cursorAt(anchor), clicks: 1 };
	}
	const unit = unitOf(e.doc, offset, clicks);
	if (add) { addPrimary(e, unit); }
	else { e.select({ ranges: [unit], primary: 0 }); }
	return { origin: unit, clicks };
}

export function drag(e: Editor, g: Gesture, offset: int32): void {
	const unit = unitOf(e.doc, offset, g.clicks);
	const origin = g.origin;
	const forward = unit.end() >= origin.end();
	replacePrimary(e, forward ? span(origin.start(), unit.end()) : span(origin.end(), unit.start()));
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
		findBar: (replace: boolean): void => {},
		findAgain: (backwards: boolean): void => {},
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

test "home, end, word and document motions, and their select forms keep the anchor" {
	const run = runner();
	const e = editorAt("\tfoo bar\nbaz", [5]);
	run(e, "home");
	assert heads(e) == "1";
	run(e, "home");
	assert heads(e) == "0";
	run(e, "end");
	assert heads(e) == "8";
	run(e, "selectHome");
	assert heads(e) == "8-1";
	run(e, "wordRight");
	assert heads(e) == "4";
	run(e, "selectWordLeft");
	assert heads(e) == "4-1";
	run(e, "docEnd");
	assert heads(e) == "12";
	run(e, "selectDocStart");
	assert heads(e) == "12-0";
	run(e, "selectEnd");
	assert heads(e) == "12-8";
	run(e, "selectWordRight");
	assert heads(e) == "12-9";
	run(e, "docStart");
	assert heads(e) == "0";
}

test "page motions move by the context's page rows and keep the goal column" {
	const run = runner();
	const e = editorAt("a\nb\nc\nd", [1]);
	run(e, "pageDown");
	assert heads(e) == "5";
	run(e, "selectPageDown");
	assert heads(e) == "5-7";
	run(e, "pageUp");
	assert heads(e) == "3";
}

test "select line takes whole lines, and select all then collapse ends at the document end" {
	const run = runner();
	const e = editorAt("one\ntwo\nthree", [5]);
	run(e, "selectLine");
	assert heads(e) == "4-8";
	e.select({ ranges: [span(1, 5)], primary: 0 });
	run(e, "selectLine");
	assert heads(e) == "0-8";
	run(e, "selectAll");
	assert heads(e) == "0-13";
	run(e, "collapse");
	assert heads(e) == "13";
}

test "cut without a selection takes the whole line, with one it takes the selection" {
	const run = runner();
	const e = editorAt("one\ntwo\nthree", [5]);
	run(e, "cut");
	assert e.doc.text() == "one\nthree";
	assert heads(e) == "4";
	run(e, "docStart");
	run(e, "paste");
	assert e.doc.text() == "two\none\nthree";
	e.select({ ranges: [span(4, 7)], primary: 0 });
	run(e, "cut");
	assert e.doc.text() == "two\n\nthree";
	assert heads(e) == "4";
	const last = editorAt("a\nb", [3]);
	run(last, "cut");
	assert last.doc.text() == "a\n";
	run(last, "paste");
	assert last.doc.text() == "a\nb\n";
}

test "delete and delete word right remove forward from each cursor, one undo step each" {
	const run = runner();
	const e = editorAt("ab cd\nef", [0, 6]);
	run(e, "delete");
	assert e.doc.text() == "b cd\nf";
	assert heads(e) == "0,5";
	run(e, "deleteWordRight");
	assert e.doc.text() == " cd\n";
	assert heads(e) == "0,4";
	run(e, "undo");
	assert e.doc.text() == "b cd\nf";
	run(e, "undo");
	assert e.doc.text() == "ab cd\nef";
}

test "outdent takes a tab or up to four spaces from each selected line" {
	const run = runner();
	const e = editorAt("      x\n\ty\nz", [0]);
	e.select({ ranges: [span(0, 11)], primary: 0 });
	run(e, "outdent");
	assert e.doc.text() == "  x\ny\nz";
	assert heads(e) == "0-6";
	run(e, "outdent");
	assert e.doc.text() == "x\ny\nz";
	assert heads(e) == "0-4";
}

test "a triple-click selects the line with its break and a drag extends by lines" {
	const e = editorAt("one\ntwo\nthree", [0]);
	const g = press(e, 5, 3, false, false);
	assert heads(e) == "4-8";
	drag(e, g, 10);
	assert heads(e) == "4-13";
	drag(e, g, 1);
	assert heads(e) == "8-0";
}

test "a cursor added above becomes primary and stops at the first line" {
	const run = runner();
	const e = editorAt("abc\nabc", [6]);
	run(e, "addCursorAbove");
	assert heads(e) == "2,6";
	assert e.selections.primary == 0;
	run(e, "addCursorAbove");
	assert heads(e) == "2,6";
}

test "next occurrence on an empty line leaves the cursor alone" {
	const run = runner();
	const e = editorAt("a\n\nb", [2]);
	run(e, "selectNextOccurrence");
	assert heads(e) == "2";
}
