import { Document } from "./document";
import { Editor } from "./editor";
import { isWordByte } from "./motion";
import { Sel, Selections, cursorAt, sameSelections, span } from "./selection";

const NEWLINE: int32 = "\n".code;
const SPACE_RUN: int32 = 0;
const PUNCT_RUN: int32 = 1;
const WORD_RUN: int32 = 2;
const TEXT_NODES = ["string", "template_string"];

export struct SyntaxNode {
	from: int32;
	to: int32;
	named: boolean;
	kind: string;
}

export type Ancestor = (from: int32, to: int32) => SyntaxNode | null;

function runOf(b: int32): int32 {
	if (isWordByte(b)) { return WORD_RUN; }
	const space = b == " ".code || b == "\t".code || b == "\r".code || b == NEWLINE;
	return space ? SPACE_RUN : PUNCT_RUN;
}

function surroundingWord(doc: Document, at: int32): [int32, int32] {
	let run = -1;
	if (at > 0) { run = runOf(doc.byteAt(at - 1)); }
	if (at < doc.length()) { run = Math.max(run, runOf(doc.byteAt(at))); }
	let from = at;
	while (from > 0 && doc.byteAt(from - 1) != NEWLINE && runOf(doc.byteAt(from - 1)) == run) {
		from -= 1;
	}
	let to = at;
	while (to < doc.length() && doc.byteAt(to) != NEWLINE && runOf(doc.byteAt(to)) == run) {
		to += 1;
	}
	return [from, to];
}

function oriented(s: Sel, from: int32, to: int32): Sel {
	return s.head < s.anchor ? span(to, from) : span(from, to);
}

function wordInText(doc: Document, s: Sel): Sel | null {
	const [from, to] = surroundingWord(doc, s.start());
	if (from == to || (from == s.start() && to == s.end())) { return null; }
	const [lastFrom, lastTo] = surroundingWord(doc, s.end());
	return from == lastFrom && to == lastTo ? oriented(s, from, to) : null;
}

function grown(doc: Document, ancestor: Ancestor, s: Sel): Sel {
	const found = ancestor(s.start(), s.end());
	if (found === null) { return s; }
	let node = found as SyntaxNode;
	if (TEXT_NODES.includes(node.kind)) {
		const word = wordInText(doc, s);
		if (word !== null) { return word as Sel; }
	}
	while (!node.named) {
		const up = ancestor(node.from, node.to);
		if (up === null) { break; }
		node = up as SyntaxNode;
	}
	return oriented(s, node.from, node.to);
}

export class Expander {
	private ancestor: Ancestor | null;
	private stack: Vec<Selections> = [];
	private after: Selections = { ranges: [], primary: 0 };
	private version: int32 = -1;

	constructor(ancestor: Ancestor | null) { this.ancestor = ancestor; }

	private keepIfCurrent(e: Editor): void {
		if (e.doc.version() != this.version || !e.selections.sameSelections(this.after)) {
			this.stack = [];
		}
	}

	private landed(e: Editor, next: Selections): void {
		e.select(next);
		this.after = e.selections;
		this.version = e.doc.version();
	}

	grow(e: Editor): boolean {
		if (this.ancestor === null) { return false; }
		const ancestor = this.ancestor as Ancestor;
		this.keepIfCurrent(e);
		const old = e.selections;
		const next: Sel[] = [];
		let changed = false;
		for (const s of old.ranges) {
			const g = grown(e.doc, ancestor, s);
			changed = changed || g.start() != s.start() || g.end() != s.end();
			next.push(g);
		}
		if (!changed) { return false; }
		if (next.length == 1) {
			const g = next[0];
			const startMoved = g.start() != old.ranges[0].start();
			next[0] = startMoved ? span(g.end(), g.start()) : span(g.start(), g.end());
		}
		this.stack.push(old);
		this.landed(e, { ranges: next, primary: old.primary });
		return true;
	}

	shrink(e: Editor): boolean {
		this.keepIfCurrent(e);
		if (this.stack.length == 0) { return false; }
		const saved = this.stack.pop();
		const ranges = saved.ranges.slice(0);
		const current = e.selections.ranges;
		if (current.length == 1) {
			const last = ranges.length - 1;
			ranges[last] = oriented(current[0], ranges[last].start(), ranges[last].end());
		}
		this.landed(e, { ranges, primary: saved.primary });
		return true;
	}
}

function smallestAround(nodes: Span<SyntaxNode>, from: int32, to: int32): SyntaxNode | null {
	let best: SyntaxNode | null = null;
	let bestWidth = 0;
	for (const n of nodes) {
		const width = n.to - n.from;
		const larger = n.from <= from && to <= n.to && width > to - from;
		if (larger && (best === null || width < bestWidth)) {
			best = n;
			bestWidth = width;
		}
	}
	return best;
}

function treeOf(nodes: SyntaxNode[]): Ancestor {
	return (from: int32, to: int32): SyntaxNode | null => smallestAround(nodes, from, to);
}

function named(from: int32, to: int32): SyntaxNode {
	return { from, to, named: true, kind: "node" };
}

function ranges(e: Editor): string {
	let out = "";
	for (const s of e.selections.ranges) { out += `${s.anchor}:${s.head} `; }
	return out;
}

function editorAt(text: string, s: Selections): Editor {
	const e = new Editor(new Document(text));
	e.select(s);
	return e;
}

const CALL = "f(a, bb)";
const CALL_TREE: SyntaxNode[] = [
	named(0, 8),
	named(0, 1),
	named(1, 8),
	named(2, 3),
	{ from: 1, to: 2, named: false, kind: "(" },
	{ from: 3, to: 4, named: false, kind: "," },
	named(5, 7),
	{ from: 7, to: 8, named: false, kind: ")" },
];

test "growing takes the smallest larger named node and shrinking walks back the same steps" {
	const e = editorAt(CALL, { ranges: [cursorAt(6)], primary: 0 });
	const expander = new Expander(treeOf(CALL_TREE));
	assert expander.grow(e);
	assert ranges(e) == "7:5 ";
	assert expander.grow(e);
	assert ranges(e) == "8:1 ";
	assert expander.grow(e);
	assert ranges(e) == "8:0 ";
	assert !expander.grow(e);
	assert expander.shrink(e);
	assert ranges(e) == "8:1 ";
	assert expander.shrink(e);
	assert ranges(e) == "7:5 ";
	assert expander.shrink(e);
	assert ranges(e) == "6:6 ";
	assert !expander.shrink(e);
}

test "an anonymous node is passed over to the named node around it" {
	const e = editorAt(CALL, { ranges: [span(3, 4)], primary: 0 });
	const expander = new Expander(treeOf(CALL_TREE));
	assert expander.grow(e);
	assert ranges(e) == "8:1 ";
}

test "each cursor grows on its own and shrinking restores every cursor" {
	const e = editorAt(CALL, { ranges: [cursorAt(2), cursorAt(6)], primary: 1 });
	const expander = new Expander(treeOf(CALL_TREE));
	assert expander.grow(e);
	assert ranges(e) == "2:3 5:7 ";
	assert expander.grow(e);
	assert ranges(e) == "1:8 ";
	assert expander.shrink(e);
	assert ranges(e) == "2:3 5:7 ";
	assert e.selections.primary == 1;
	assert expander.shrink(e);
	assert ranges(e) == "2:2 6:6 ";
}

test "a selection changed any other way, or an edit, drops the way back" {
	const e = editorAt(CALL, { ranges: [cursorAt(6)], primary: 0 });
	const expander = new Expander(treeOf(CALL_TREE));
	assert expander.grow(e);
	e.select({ ranges: [cursorAt(2)], primary: 0 });
	assert !expander.shrink(e);
	assert expander.grow(e);
	assert ranges(e) == "2:3 ";
	e.replaceSelections("c");
	e.select({ ranges: [span(2, 3)], primary: 0 });
	assert !expander.shrink(e);
}

test "inside a string the word comes before the string" {
	const text = "\"one two\"";
	const tree: SyntaxNode[] = [{ from: 0, to: 9, named: true, kind: "string" }];
	const e = editorAt(text, { ranges: [cursorAt(6)], primary: 0 });
	const expander = new Expander(treeOf(tree));
	assert expander.grow(e);
	assert ranges(e) == "8:5 ";
	assert expander.grow(e);
	assert ranges(e) == "9:0 ";
}

test "without a tree nothing grows" {
	const e = editorAt(CALL, { ranges: [cursorAt(6)], primary: 0 });
	const expander = new Expander(null);
	assert !expander.grow(e);
	assert !expander.shrink(e);
	assert ranges(e) == "6:6 ";
}
