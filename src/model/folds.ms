import { Anchor, Bias, Document } from "./document";
import { Editor } from "./editor";
import { Ancestor, SyntaxNode } from "./expand";
import { indentEnd } from "./motion";
import { Sel, Selections, cursorAt, end, span, start } from "./selection";

export const PLACEHOLDER = "⋯";
const CLOSERS = ")]}";
const TEXT_NODES = ["string", "template_string", "comment"];
const NO_LIMIT: int32 = 0x7FFFFFFF;

export struct Fold {
	from: int32;
	to: int32;
}

export enum Toggle {
	None,
	Open,
	Folded,
}

struct Kept {
	from: Anchor;
	to: Anchor;
}

function firstEndingAfter(folds: Fold[], offset: int32): int32 {
	let low = 0;
	let high = folds.length as int32;
	while (low < high) {
		const middle = (low + high) >> 1;
		if (folds[middle].to > offset) { high = middle; } else { low = middle + 1; }
	}
	return low;
}

export function foldHolding(folds: Fold[], offset: int32): Fold | null {
	const k = firstEndingAfter(folds, offset);
	return k < (folds.length as int32) && folds[k].from < offset ? folds[k] : null;
}

export function foldsWithin(folds: Fold[], from: int32, to: int32): Fold[] {
	const out: Fold[] = [];
	for (let k = firstEndingAfter(folds, from); k < (folds.length as int32) && folds[k].from < to; k++) {
		out.push(folds[k]);
	}
	return out;
}

export function lineHidden(this doc: Document, folds: Fold[], line: int32): boolean {
	if (folds.length == 0) { return false; }
	const start = doc.lineStart(line);
	const k = firstEndingAfter(folds, start - 1);
	return k < (folds.length as int32) && folds[k].from < start;
}

export function shownLine(this doc: Document, folds: Fold[], line: int32): int32 {
	let at = line;
	while (doc.lineHidden(folds, at)) {
		at = doc.lineOf(folds[firstEndingAfter(folds, doc.lineStart(at) - 1)].from);
	}
	return at;
}

export function shownEnd(this doc: Document, folds: Fold[], line: int32): int32 {
	let end = doc.lineEnd(line);
	for (let k = firstEndingAfter(folds, doc.lineStart(line)); k < (folds.length as int32) && folds[k].from <= end; k++) {
		end = doc.lineEnd(doc.lineOf(folds[k].to));
	}
	return end;
}

export function lineAfter(this doc: Document, folds: Fold[], line: int32): int32 {
	if (folds.length == 0) { return line + 1; }
	return doc.lineOf(doc.shownEnd(folds, doc.shownLine(folds, line))) + 1;
}

export function lineFolded(this doc: Document, folds: Fold[], line: int32): boolean {
	if (folds.length == 0) { return false; }
	const k = firstEndingAfter(folds, doc.lineStart(line));
	return k < (folds.length as int32) && folds[k].from <= doc.lineEnd(line);
}

function indentOf(this doc: Document, line: int32): int32 {
	return doc.indentEnd(line) - doc.lineStart(line);
}

function isBlank(this doc: Document, line: int32): boolean {
	return doc.indentEnd(line) == doc.lineEnd(line);
}

export function startsIndent(this doc: Document, line: int32): boolean {
	const last = doc.lineCount() - 1;
	if (line >= last || doc.isBlank(line)) { return false; }
	const indent = doc.indentOf(line);
	for (let next = line + 1; next <= last; next++) {
		if (doc.indentOf(next) > indent) { return true; }
		if (!doc.isBlank(next)) { return false; }
	}
	return false;
}

function filledEnd(this doc: Document, line: int32, floor: int32): int32 {
	let at = line;
	while (at > floor && doc.isBlank(at)) { at -= 1; }
	return doc.lineEnd(at);
}

function closes(this doc: Document, line: int32): boolean {
	const at = doc.indentEnd(line);
	return at < doc.lineEnd(line) && CLOSERS.includes(String.fromCharCode(doc.byteAt(at)));
}

function linesOf(doc: Document, s: Sel): [int32, int32] {
	return [doc.lineOf(s.start()), doc.lineOf(s.end())];
}

function crosses(r: Fold, from: int32, to: int32, inclusive: boolean): boolean {
	return inclusive ? r.from <= to && r.to >= from : r.from < to && r.to > from;
}

export class Folds {
	private ancestor: Ancestor | null;
	private doc: Document | null = null;
	private kept: Vec<Kept> = [];
	private merged: Fold[] = [];
	private mergedAt: int32 = -1;

	constructor(ancestor: Ancestor | null) { this.ancestor = ancestor; }

	private bind(doc: Document): void {
		if (this.doc === null) {
			this.doc = doc;
			return;
		}
		if (this.doc !== doc) { throw new Error("Folds: one set of folds belongs to one document"); }
	}

	count(): int32 { return this.kept.length as int32; }

	shown(doc: Document): Fold[] {
		if (this.kept.length == 0) { return this.merged; }
		this.bind(doc);
		if (doc.version() != this.mergedAt) { this.remerge(doc); }
		return this.merged;
	}

	private remerge(doc: Document): void {
		let live: Vec<Kept> = [];
		const spans: Fold[] = [];
		for (const k of this.kept) {
			const from = doc.resolve(k.from);
			const to = doc.resolve(k.to);
			if (to > from) {
				live.push(k);
				spans.push({ from, to });
			} else {
				doc.release(k.from);
				doc.release(k.to);
			}
		}
		this.kept = live;
		spans.sort((a: Fold, b: Fold): number => a.from != b.from ? a.from - b.from : b.to - a.to);
		const merged: Fold[] = [];
		for (const s of spans) {
			const last = (merged.length as int32) - 1;
			if (last >= 0 && s.from <= merged[last].to) {
				merged[last].to = Math.max(merged[last].to, s.to);
			} else {
				merged.push(s);
			}
		}
		this.merged = merged;
		this.mergedAt = doc.version();
	}

	private changed(): void {
		this.mergedAt = -1;
		if (this.kept.length == 0) { this.merged = []; }
	}

	private add(e: Editor, found: Fold[]): boolean {
		const doc = e.doc;
		this.bind(doc);
		const have = new Set<string>();
		for (const k of this.kept) { have.add(`${doc.resolve(k.from)}:${doc.resolve(k.to)}`); }
		let added = false;
		for (const f of found) {
			const key = `${f.from}:${f.to}`;
			if (f.to <= f.from || have.has(key)) { continue; }
			have.add(key);
			this.kept.push({ from: doc.anchor(f.from, Bias.Right), to: doc.anchor(f.to, Bias.Left) });
			added = true;
		}
		if (!added) { return false; }
		this.changed();
		this.clip(e);
		return true;
	}

	private removeCrossing(doc: Document, ranges: Fold[], inclusive: boolean): boolean {
		if (this.kept.length == 0 || ranges.length == 0) { return false; }
		let live: Vec<Kept> = [];
		for (const k of this.kept) {
			const fold: Fold = { from: doc.resolve(k.from), to: doc.resolve(k.to) };
			let hit = false;
			for (const r of ranges) { hit = hit || crosses(r, fold.from, fold.to, inclusive); }
			if (hit) {
				doc.release(k.from);
				doc.release(k.to);
			} else {
				live.push(k);
			}
		}
		const removed = live.length != this.kept.length;
		this.kept = live;
		this.changed();
		return removed;
	}

	clipped(doc: Document, offset: int32, right: boolean): int32 {
		const f = foldHolding(this.shown(doc), offset);
		if (f === null) { return offset; }
		return right ? (f as Fold).to : (f as Fold).from;
	}

	private clip(e: Editor): void {
		const doc = e.doc;
		const next: Sel[] = [];
		let moved = false;
		for (const s of e.selections.ranges) {
			const forward = s.anchor <= s.head;
			const anchor = this.clipped(doc, s.anchor, !forward);
			const head = this.clipped(doc, s.head, forward && !s.isEmpty());
			moved = moved || anchor != s.anchor || head != s.head;
			next.push(s.isEmpty() ? cursorAt(head) : span(anchor, head));
		}
		if (moved) { e.select({ ranges: next, primary: e.selections.primary }); }
	}

	private inText(offset: int32): boolean {
		if (this.ancestor === null) { return false; }
		const ancestor = this.ancestor as Ancestor;
		let node = ancestor(offset, offset);
		if (node !== null && !(node as SyntaxNode).named) {
			node = ancestor((node as SyntaxNode).from, (node as SyntaxNode).to);
		}
		return node !== null && TEXT_NODES.includes((node as SyntaxNode).kind);
	}

	foldable(doc: Document, line: int32): Fold | null {
		const folds = this.shown(doc);
		if (!doc.startsIndent(line) || doc.lineFolded(folds, line)) { return null; }
		const indent = doc.indentOf(line);
		const last = doc.lineCount() - 1;
		let nodeEnd = -1;
		if (this.ancestor !== null) {
			const node = (this.ancestor as Ancestor)(doc.lineStart(line), doc.lineEnd(line));
			if (node !== null) { nodeEnd = (node as SyntaxNode).to; }
		}
		let closing = -1;
		for (let row = line + 1; row <= last && closing < 0; row++) {
			if (doc.isBlank(row) || doc.indentOf(row) > indent) { continue; }
			if (doc.lineStart(row) < nodeEnd && this.inText(doc.lineStart(row))) { continue; }
			closing = row;
		}
		const to = closing < 0
			? doc.filledEnd(last, line)
			: doc.closes(closing) ? doc.indentEnd(closing) : doc.filledEnd(closing - 1, line);
		return { from: doc.lineEnd(line), to };
	}

	private hasCrease(doc: Document, line: int32): boolean {
		return doc.startsIndent(line) && !doc.lineFolded(this.shown(doc), line);
	}

	private enclosing(doc: Document, line: int32, recursive: boolean): Fold[] {
		const out: Fold[] = [];
		let limit = NO_LIMIT;
		for (let row = line; row >= 0 && limit > 0; row--) {
			const indent = doc.indentOf(row);
			if (row == line || indent < limit) {
				const crease = this.foldable(doc, row);
				if (crease !== null) {
					if (doc.lineOf((crease as Fold).to) < line) {
						if (recursive) { return out; }
					} else {
						out.push(crease as Fold);
						if (!recursive) { return out; }
					}
				}
			} else if (recursive && this.hasCrease(doc, row)) {
				return out;
			}
			if (row < line && indent < limit && !doc.isBlank(row) && !this.inText(doc.lineStart(row))) {
				limit = indent;
			}
		}
		return out;
	}

	private within(doc: Document, first: int32, last: int32, out: Fold[], skipNested: boolean): boolean {
		let any = false;
		let row = first;
		while (row <= last) {
			const crease = this.foldable(doc, row);
			if (crease === null) {
				row += 1;
				continue;
			}
			any = true;
			out.push(crease as Fold);
			row = skipNested ? doc.lineOf((crease as Fold).to) + 1 : row + 1;
		}
		return any;
	}

	fold(e: Editor): boolean {
		const doc = e.doc;
		const found: Fold[] = [];
		for (const s of e.selections.ranges) {
			const [first, last] = linesOf(doc, s);
			if (first != last && this.within(doc, first, last, found, true)) { continue; }
			for (const f of this.enclosing(doc, first, false)) { found.push(f); }
		}
		return this.add(e, found);
	}

	foldRecursive(e: Editor): boolean {
		const doc = e.doc;
		const found: Fold[] = [];
		for (const s of e.selections.ranges) {
			const [first, last] = linesOf(doc, s);
			if (first != last && this.within(doc, first, last, found, false)) { continue; }
			for (const f of this.enclosing(doc, first, true)) { found.push(f); }
		}
		return this.add(e, found);
	}

	foldAll(e: Editor): boolean {
		const found: Fold[] = [];
		const _any = this.within(e.doc, 0, e.doc.lineCount() - 2, found, false);
		return this.add(e, found);
	}

	foldAtLevel(e: Editor, level: int32): boolean {
		const doc = e.doc;
		const kept: Array<[int32, int32]> = [];
		for (const s of e.selections.ranges) { kept.push(linesOf(doc, s)); }
		const found: Fold[] = [];
		const stack: Array<[int32, int32, int32]> = [[0, doc.lineCount() - 1, 1]];
		while (stack.length > 0) {
			const top = stack.pop();
			let row = top[0];
			const depth = top[2];
			while (row < top[1]) {
				const crease = this.foldable(doc, row);
				if (crease === null) {
					row += 1;
					continue;
				}
				const inner = row + 1;
				const bottom = doc.lineOf((crease as Fold).to);
				if (depth < level) {
					stack.push([inner, bottom, depth + 1]);
				} else if (depth == level) {
					let holds = false;
					for (const k of kept) { holds = holds || (k[1] >= inner && k[0] <= bottom); }
					if (!holds) { found.push(crease as Fold); }
				}
				row = Math.max(row + 1, bottom);
			}
		}
		return this.add(e, found);
	}

	foldLine(e: Editor, line: int32): boolean {
		const crease = this.foldable(e.doc, line);
		return crease !== null && this.add(e, [crease as Fold]);
	}

	unfoldLines(e: Editor): boolean {
		const doc = e.doc;
		const ranges: Fold[] = [];
		for (const s of e.selections.ranges) {
			ranges.push({ from: doc.lineStart(doc.lineOf(s.start())), to: doc.lineEnd(doc.lineOf(s.end())) });
		}
		return this.removeCrossing(doc, ranges, true);
	}

	unfoldRecursive(e: Editor): boolean {
		const doc = e.doc;
		const folds = this.shown(doc);
		const ranges: Fold[] = [];
		for (const s of e.selections.ranges) {
			const last = doc.shownLine(folds, doc.lineOf(s.end()));
			ranges.push({
				from: doc.lineStart(doc.shownLine(folds, doc.lineOf(s.start()))),
				to: doc.shownEnd(folds, last),
			});
		}
		return this.removeCrossing(doc, ranges, true);
	}

	unfoldAll(e: Editor): boolean {
		return this.removeCrossing(e.doc, [{ from: 0, to: e.doc.length() }], true);
	}

	toggleFold(e: Editor): boolean {
		const doc = e.doc;
		const folds = this.shown(doc);
		const s = e.selections.primaryRange();
		let from = s.start();
		let to = s.end();
		if (s.isEmpty()) {
			const line = doc.shownLine(folds, doc.lineOf(s.head));
			from = doc.lineStart(line);
			to = doc.shownEnd(folds, line);
		}
		for (const f of folds) {
			if (crosses(f, from, to, false)) { return this.unfoldLines(e); }
		}
		return this.fold(e);
	}

	unfoldLine(doc: Document, line: int32): boolean {
		return this.removeCrossing(doc, [{ from: doc.lineStart(line), to: doc.lineEnd(line) }], true);
	}

	unfoldShown(doc: Document, from: int32): boolean {
		for (const f of this.shown(doc)) {
			if (f.from == from) { return this.removeCrossing(doc, [f], true); }
		}
		return false;
	}

	reveal(e: Editor): boolean {
		const folds = this.shown(e.doc);
		if (folds.length == 0) { return false; }
		const ranges: Fold[] = [];
		for (const s of e.selections.ranges) {
			if (foldHolding(folds, s.anchor) !== null) { ranges.push({ from: s.anchor, to: s.anchor }); }
			if (foldHolding(folds, s.head) !== null) { ranges.push({ from: s.head, to: s.head }); }
		}
		return this.removeCrossing(e.doc, ranges, true);
	}

	toggleAt(doc: Document, line: int32, offered: boolean): Toggle {
		if (doc.lineFolded(this.shown(doc), line)) { return Toggle.Folded; }
		return offered && doc.startsIndent(line) ? Toggle.Open : Toggle.None;
	}
}

const BLOCKS = "function f() {\n  if (x) {\n    a();\n\n    b();\n  }\n  c();\n}\nd();\n";

function editorAt(text: string, s: Selections): Editor {
	const e = new Editor(new Document(text));
	e.select(s);
	return e;
}

function shownText(e: Editor, folds: Folds): string {
	const doc = e.doc;
	let out = "";
	let at = 0;
	for (const f of folds.shown(doc)) {
		out += doc.slice(at, f.from) + PLACEHOLDER;
		at = f.to;
	}
	return out + doc.slice(at, doc.length());
}

function caretAt(offset: int32): Selections {
	return { ranges: [cursorAt(offset)], primary: 0 };
}

test "a line that starts an indent folds to the line before its closing bracket's line" {
	const e = editorAt(BLOCKS, caretAt(0));
	const folds = new Folds(null);
	assert e.doc.startsIndent(0) && !e.doc.startsIndent(2) && e.doc.startsIndent(1);
	assert folds.fold(e);
	assert shownText(e, folds) == "function f() {⋯}\nd();\n";
	assert !folds.fold(e) && folds.count() == 1;
	assert folds.unfoldLines(e);
	assert shownText(e, folds) == BLOCKS && folds.count() == 0;
}

test "without a closing bracket the fold ends at the last filled line of the block" {
	const text = "def f():\n    a\n\n    b\n\nc\n";
	const e = editorAt(text, caretAt(0));
	const folds = new Folds(null);
	assert folds.fold(e);
	assert shownText(e, folds) == "def f():⋯\n\nc\n";
}

test "fold takes the innermost block around the caret, then the next one out" {
	const e = editorAt(BLOCKS, caretAt(BLOCKS.byteIndexOf("a();")));
	const folds = new Folds(null);
	assert folds.fold(e);
	assert shownText(e, folds) == "function f() {\n  if (x) {⋯}\n  c();\n}\nd();\n";
	assert e.selections.primaryRange().head == BLOCKS.byteIndexOf("\n    a();");
	assert folds.fold(e);
	assert shownText(e, folds) == "function f() {⋯}\nd();\n";
	assert folds.count() == 2;
	assert folds.unfoldLines(e);
	assert shownText(e, folds) == "function f() {\n  if (x) {⋯}\n  c();\n}\nd();\n";
}

test "a caret on the closing line folds the block it closes" {
	const e = editorAt(BLOCKS, caretAt(BLOCKS.byteIndexOf("  }")));
	const folds = new Folds(null);
	assert folds.fold(e);
	assert shownText(e, folds) == "function f() {\n  if (x) {⋯}\n  c();\n}\nd();\n";
}

test "recursive folding takes every block around the caret, and recursive unfolding opens them all" {
	const e = editorAt(BLOCKS, caretAt(BLOCKS.byteIndexOf("b();")));
	const folds = new Folds(null);
	assert folds.foldRecursive(e);
	assert folds.count() == 2;
	assert shownText(e, folds) == "function f() {⋯}\nd();\n";
	assert folds.unfoldLines(e) && folds.count() == 1;
	assert folds.fold(e) && folds.count() == 2;
	assert folds.unfoldRecursive(e) && folds.count() == 0;
}

test "fold all folds every block, and a level folds only the blocks that deep" {
	const text = "a {\n  b {\n    x\n  }\n}\nc {\n  y\n}\n";
	const e = editorAt(text, caretAt(text.byteLength));
	const folds = new Folds(null);
	assert folds.foldAll(e);
	assert folds.count() == 3;
	assert shownText(e, folds) == "a {⋯}\nc {⋯}\n";
	assert folds.unfoldAll(e) && folds.count() == 0;
	assert folds.foldAtLevel(e, 2);
	assert shownText(e, folds) == "a {\n  b {⋯}\n}\nc {\n  y\n}\n";
	const _none = folds.unfoldAll(e);
	e.select(caretAt(text.byteIndexOf("y")));
	assert folds.foldAtLevel(e, 1);
	assert shownText(e, folds) == "a {⋯}\nc {\n  y\n}\n";
}

test "toggling folds an open line and unfolds a folded one" {
	const e = editorAt(BLOCKS, caretAt(3));
	const folds = new Folds(null);
	assert folds.toggleFold(e);
	assert folds.count() == 1;
	assert folds.toggleFold(e);
	assert folds.count() == 0;
}

test "edits move a fold, and deleting all it holds drops it" {
	const e = editorAt(BLOCKS, caretAt(0));
	const folds = new Folds(null);
	assert folds.fold(e);
	const doc = e.doc;
	const _a = doc.splice({ from: 0, to: 0, text: "// x\n" });
	assert shownText(e, folds) == "// x\nfunction f() {⋯}\nd();\n";
	const f = folds.shown(doc)[0];
	const _b = doc.splice({ from: f.from, to: f.from, text: " " });
	assert shownText(e, folds) == "// x\nfunction f() { ⋯}\nd();\n";
	const g = folds.shown(doc)[0];
	const _c = doc.splice({ from: g.to, to: g.to, text: "!" });
	assert shownText(e, folds) == "// x\nfunction f() { ⋯!}\nd();\n";
	const h = folds.shown(doc)[0];
	const _d = doc.splice({ from: h.from, to: h.to, text: "" });
	assert folds.shown(doc).length == 0 && folds.count() == 0;
}

test "a caret inside a new fold moves to its start, and revealing a selection inside a fold opens it" {
	const e = editorAt(BLOCKS, { ranges: [cursorAt(BLOCKS.byteIndexOf("c();"))], primary: 0 });
	const folds = new Folds(null);
	assert folds.foldLine(e, 0);
	assert e.selections.primaryRange().head == BLOCKS.byteIndexOf("\n");
	assert folds.clipped(e.doc, 20, true) == BLOCKS.byteIndexOf("}\nd");
	e.select(caretAt(20));
	assert folds.reveal(e) && folds.count() == 0;
}

test "display lines join the lines a fold hides" {
	const e = editorAt(BLOCKS, caretAt(0));
	const folds = new Folds(null);
	assert folds.foldLine(e, 1);
	const doc = e.doc;
	const shown = folds.shown(doc);
	assert !doc.lineHidden(shown, 1) && doc.lineHidden(shown, 2) && doc.lineHidden(shown, 5) && !doc.lineHidden(shown, 6);
	assert doc.shownLine(shown, 5) == 1 && doc.shownLine(shown, 6) == 6;
	assert doc.shownEnd(shown, 1) == doc.lineEnd(5) && doc.lineAfter(shown, 1) == 6 && doc.lineAfter(shown, 3) == 6;
	assert doc.lineFolded(shown, 1) && doc.lineFolded(shown, 3) && !doc.lineFolded(shown, 0);
	assert folds.toggleAt(doc, 1, false) == Toggle.Folded && folds.toggleAt(doc, 0, true) == Toggle.Open;
	assert folds.toggleAt(doc, 0, false) == Toggle.None && folds.toggleAt(doc, 6, true) == Toggle.None;
	assert folds.foldable(doc, 1) === null;
	assert folds.unfoldLine(doc, 1) && folds.count() == 0;
}

test "lines inside a string or comment do not end the block they sit in" {
	const text = "f() {\n  s = `\nraw\n`;\n  g();\n}\n";
	const nodes: SyntaxNode[] = [
		{ from: 0, to: text.byteLength, named: true, kind: "program" },
		{ from: text.byteIndexOf("`"), to: text.byteIndexOf(";"), named: true, kind: "template_string" },
		{ from: text.byteIndexOf(";") - 1, to: text.byteIndexOf(";"), named: false, kind: "`" },
	];
	const ancestor = (from: int32, to: int32): SyntaxNode | null => {
		let best: SyntaxNode | null = null;
		for (const n of nodes) {
			if (n.from <= from && to <= n.to && n.to - n.from > to - from) { best = n; }
		}
		return best;
	};
	const e = editorAt(text, caretAt(0));
	const plain = new Folds(null);
	assert plain.fold(e);
	assert shownText(e, plain) == "f() {⋯\nraw\n`;\n  g();\n}\n";
	const _gone = plain.unfoldAll(e);
	const aware = new Folds(ancestor);
	assert aware.fold(e);
	assert shownText(e, aware) == "f() {⋯}\n";
}
