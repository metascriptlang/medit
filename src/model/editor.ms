import { Bias, Change, Document, Edit, mapOffset } from "./document";
import { Sel, Selections, cursorAt, normalized, sameSelections, single, span } from "./selection";

export struct Step {
	edits: Edit[];
	before: Selections;
	after: Selections;
}

export function mapThrough(offset: int32, changes: Span<Change>, bias: Bias): int32 {
	let at = offset;
	for (const c of changes) { at = mapOffset(at, c, bias); }
	return at;
}

export class Editor {
	doc: Document;
	selections: Selections = single(0);
	private undos: Vec<Step> = [];
	private redos: Vec<Step> = [];
	private depth: int32 = 0;
	private pending: Edit[] = [];
	private pendingBefore: Selections = single(0);
	private group: string = "";
	private lastGroup: string = "";

	constructor(doc: Document) {
		this.doc = doc;
	}

	select(next: Selections): void {
		for (const s of next.ranges) {
			if (s.start() < 0 || s.end() > this.doc.length()) {
				throw new Error(
					`Editor.select: ${s.anchor}..${s.head} is outside 0..${this.doc.length()}`,
				);
			}
		}
		this.selections = next.normalized();
	}

	begin(): void {
		if (this.depth == 0) {
			this.pending = [];
			this.pendingBefore = this.selections;
			this.group = "";
		}
		this.depth += 1;
	}

	groupAs(name: string): void {
		if (this.depth == 0) { throw new Error("Editor.groupAs: no transaction is open"); }
		this.group = name;
	}

	end(): void {
		if (this.depth == 0) { throw new Error("Editor.end: no transaction is open"); }
		this.depth -= 1;
		if (this.depth > 0 || this.pending.length == 0) { return; }
		const last = this.undos.length - 1;
		if (this.group != "" && this.group == this.lastGroup && last >= 0 &&
			this.undos[last].after.sameSelections(this.pendingBefore)) {
			for (const e of this.pending) { this.undos[last].edits.push(e); }
			this.undos[last].after = this.selections;
		} else {
			this.undos.push({
				edits: this.pending,
				before: this.pendingBefore,
				after: this.selections,
			});
		}
		this.lastGroup = this.group;
		this.redos = [];
	}

	change(edits: Span<Edit>): Change[] {
		if (this.depth == 0) {
			throw new Error("Editor.change: an edit needs an open transaction");
		}
		const applied: Change[] = [];
		let delta = 0;
		let lastTo = 0;
		for (const e of edits) {
			if (e.from < lastTo || e.from > e.to) {
				throw new Error(`Editor.change: edit ${e.from}..${e.to} overlaps the one before` +
					" or runs backwards");
			}
			lastTo = e.to;
			const from = e.from + delta;
			const to = e.to + delta;
			const inverse = this.doc.splice({ from, to, text: e.text });
			const inserted = inverse.to - inverse.from;
			this.pending.push(inverse);
			applied.push({ from, removed: to - from, inserted });
			delta += inserted - (to - from);
		}
		return applied;
	}

	replaceEach(texts: Span<string>): void {
		const ranges = this.selections.ranges;
		if (texts.length != ranges.length) {
			throw new Error(
				`Editor.replaceEach: ${texts.length} texts for ${ranges.length} selections`,
			);
		}
		const edits: Edit[] = [];
		for (let i = 0; i < texts.length; i++) {
			const s = ranges[i];
			edits.push({ from: s.start(), to: s.end(), text: texts[i] });
		}
		this.begin();
		const applied = this.change(edits);
		const next: Sel[] = [];
		for (const c of applied) { next.push(cursorAt(c.from + c.inserted)); }
		this.selections = { ranges: next, primary: this.selections.primary };
		this.end();
	}

	replaceSelections(text: string): void {
		const texts: string[] = [];
		for (const _s of this.selections.ranges) { texts.push(text); }
		this.replaceEach(texts);
	}

	canUndo(): boolean { return this.undos.length > 0; }
	canRedo(): boolean { return this.redos.length > 0; }
	undo(): boolean { return this.travel(this.undos, this.redos, "undo"); }
	redo(): boolean { return this.travel(this.redos, this.undos, "redo"); }

	private travel(ref from: Vec<Step>, ref into: Vec<Step>, who: string): boolean {
		if (this.depth > 0) { throw new Error(`Editor.${who}: a transaction is open`); }
		if (from.length == 0) { return false; }
		const step = from.pop();
		const inverses: Edit[] = [];
		for (let i = step.edits.length - 1; i >= 0; i--) {
			inverses.push(this.doc.splice(step.edits[i]));
		}
		into.push({ edits: inverses, before: step.after, after: step.before });
		this.selections = step.before;
		this.lastGroup = "";
		return true;
	}
}

function editorWith(text: string, cursors: Span<int32>): Editor {
	const e = new Editor(new Document(text));
	const ranges: Sel[] = [];
	for (const c of cursors) { ranges.push(cursorAt(c)); }
	e.select({ ranges, primary: 0 });
	return e;
}

function typed(e: Editor, text: string): void {
	e.begin();
	e.groupAs("type");
	e.replaceSelections(text);
	e.end();
}

test "typing at several cursors inserts at each and moves each cursor" {
	const e = editorWith("ab\ncd\nef", [1, 4, 7]);
	e.replaceSelections("X");
	assert e.doc.text() == "aXb\ncXd\neXf";
	assert e.selections.ranges[0].head == 2;
	assert e.selections.ranges[1].head == 6;
	assert e.selections.ranges[2].head == 10;
}

test "inserted CRLF lands as LF and later cursors shift by what landed" {
	const e = editorWith("ab\ncd", [1, 4]);
	e.replaceSelections("X\r\nY");
	assert e.doc.text() == "aX\nYb\ncX\nYd";
	assert e.selections.ranges[0].head == 4;
	assert e.selections.ranges[1].head == 10;
}

test "typing over selections replaces each range" {
	const e = editorWith("one two three", [0]);
	e.select({ ranges: [span(0, 3), span(8, 13)], primary: 0 });
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

test "undo and redo restore each side's selections, round after round" {
	const e = editorWith("ab", [1]);
	e.replaceSelections("X");
	e.select(single(0));
	e.replaceSelections("Y");
	for (let round = 0; round < 2; round++) {
		assert e.undo();
		assert e.selections.ranges[0].head == 0;
		assert e.undo();
		assert e.selections.ranges[0].head == 1;
		assert e.doc.text() == "ab";
		assert e.redo();
		assert e.selections.ranges[0].head == 2;
		assert e.redo();
		assert e.selections.ranges[0].head == 1;
		assert e.doc.text() == "YaXb";
	}
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
	try { const _c = e.change([{ from: 0, to: 1, text: "" }]); } catch (err) { refused = true; }
	assert refused;
}

test "typing in one place coalesces into one step until the cursor moves" {
	const e = editorWith("", [0]);
	typed(e, "a");
	typed(e, "b");
	typed(e, "c");
	e.select(single(1));
	typed(e, "X");
	assert e.doc.text() == "aXbc";
	assert e.undo();
	assert e.doc.text() == "abc";
	assert e.undo();
	assert e.doc.text() == "";
	assert e.selections.ranges[0].head == 0;
}

test "edits at several places shift by what came before" {
	const e = editorWith("0123456789", [0]);
	e.begin();
	const applied = e.change([
		{ from: 1, to: 3, text: "" },
		{ from: 5, to: 5, text: "abc" },
		{ from: 8, to: 9, text: "Z" },
	]);
	e.end();
	assert e.doc.text() == "034abc567Z9";
	assert applied[1].from == 3;
	assert mapThrough(9, applied, Bias.Left) == 10;
}
