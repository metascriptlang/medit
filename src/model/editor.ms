import { Document, Edit } from "./document";
import { Sel, Selections, cursorAt, normalized, single } from "./selection";

export struct Step {
	edits: Edit[];
	before: Selections;
	after: Selections;
}

export class Editor {
	doc: Document;
	selections: Selections;
	private undos: Step[];
	private redos: Step[];
	private depth: int32;
	private pending: Edit[];
	private pendingBefore: Selections;

	constructor(doc: Document) {
		this.doc = doc;
		this.selections = single(0);
		this.undos = [];
		this.redos = [];
		this.depth = 0;
		this.pending = [];
		this.pendingBefore = this.selections;
	}

	select(next: Selections): void {
		for (const s of next.ranges) {
			if (s.start() < 0 || s.end() > this.doc.length()) {
				throw new Error(`Editor.select: ${s.anchor}..${s.head} is outside 0..${this.doc.length()}`);
			}
		}
		this.selections = normalized(next);
	}

	begin(): void {
		if (this.depth == 0) {
			this.pending = [];
			this.pendingBefore = this.selections;
		}
		this.depth += 1;
	}

	end(): void {
		if (this.depth == 0) { throw new Error("Editor.end: no transaction is open"); }
		this.depth -= 1;
		if (this.depth > 0 || this.pending.length == 0) { return; }
		this.undos.push({ edits: this.pending, before: this.pendingBefore, after: this.selections });
		this.redos = [];
	}

	apply(edit: Edit): void {
		if (this.depth == 0) { throw new Error("Editor.apply: an edit needs an open transaction"); }
		this.pending.push(this.doc.splice(edit));
	}

	replaceSelections(text: string): void {
		this.begin();
		const next: Sel[] = [];
		let delta = 0;
		for (const s of this.selections.ranges) {
			const from = s.start() + delta;
			const to = s.end() + delta;
			this.apply({ from, to, text });
			next.push(cursorAt(from + (text.length as int32)));
			delta += (text.length as int32) - (to - from);
		}
		this.selections = { ranges: next, primary: this.selections.primary };
		this.end();
	}

	canUndo(): boolean { return this.undos.length > 0; }
	canRedo(): boolean { return this.redos.length > 0; }

	undo(): boolean {
		if (this.depth > 0) { throw new Error("Editor.undo: a transaction is open"); }
		if (this.undos.length == 0) { return false; }
		const step = this.undos.pop();
		this.redos.push({ ...step, edits: this.replay(step.edits) });
		this.selections = step.before;
		return true;
	}

	redo(): boolean {
		if (this.depth > 0) { throw new Error("Editor.redo: a transaction is open"); }
		if (this.redos.length == 0) { return false; }
		const step = this.redos.pop();
		this.undos.push({ ...step, edits: this.replay(step.edits) });
		this.selections = step.after;
		return true;
	}

	private replay(edits: Edit[]): Edit[] {
		const inverses: Edit[] = [];
		for (let i = edits.length - 1; i >= 0; i--) { inverses.push(this.doc.splice(edits[i])); }
		return inverses;
	}
}

function editorWith(text: string, cursors: int32[]): Editor {
	const e = new Editor(new Document(text));
	const ranges: Sel[] = [];
	for (const c of cursors) { ranges.push(cursorAt(c)); }
	e.select({ ranges, primary: 0 });
	return e;
}

test "typing at several cursors inserts at each and moves each cursor" {
	const e = editorWith("ab\ncd\nef", [1, 4, 7]);
	e.replaceSelections("X");
	assert e.doc.text() == "aXb\ncXd\neXf";
	assert e.selections.ranges[0].head == 2;
	assert e.selections.ranges[1].head == 6;
	assert e.selections.ranges[2].head == 10;
}

test "typing over selections replaces each range" {
	const e = editorWith("one two three", [0]);
	e.select({ ranges: [{ anchor: 0, head: 3 }, { anchor: 8, head: 13 }], primary: 0 });
	e.replaceSelections("1");
	assert e.doc.text() == "1 two 1";
	assert e.selections.ranges[1].head == 7;
}

test "one multi-cursor keystroke is one undo step" {
	const e = editorWith("ab\ncd", [1, 4]);
	e.replaceSelections("XY");
	e.replaceSelections("Z");
	assert e.doc.text() == "aXYZb\ncXYZd";
	assert e.undo();
	assert e.doc.text() == "aXYb\ncXYd";
	assert e.undo();
	assert e.doc.text() == "ab\ncd";
	assert e.selections.ranges[1].head == 4;
	assert !e.undo();
}

test "redo replays what undo took back, and a new edit clears redo" {
	const e = editorWith("abc", [3]);
	e.replaceSelections("d");
	assert e.undo();
	assert e.redo();
	assert e.doc.text() == "abcd";
	assert e.selections.ranges[0].head == 4;
	assert e.undo();
	e.replaceSelections("!");
	assert !e.canRedo();
	assert e.doc.text() == "abc!";
}

test "nested transactions make one step" {
	const e = editorWith("", [0]);
	e.begin();
	e.replaceSelections("a");
	e.replaceSelections("b");
	e.end();
	assert e.doc.text() == "ab";
	assert e.undo();
	assert e.doc.text() == "";
	assert !e.canUndo();
}

test "an edit outside a transaction is refused" {
	const e = editorWith("abc", [0]);
	let refused = false;
	try { e.apply({ from: 0, to: 1, text: "" }); } catch (err) { refused = true; }
	assert refused;
}
