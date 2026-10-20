export const LEAF_MAX: int32 = 2048;
const LEAF_MIN: int32 = LEAF_MAX / 2;
const SPLIT_SLACK: int32 = 4;
export const BRANCH_MAX: int32 = 12;
const BRANCH_MIN: int32 = BRANCH_MAX / 2;
const NEWLINE: int32 = 10;
const RETURN: int32 = 13;

// Child sizes live in the parent: reading each child's own field made a random line() 27 us
// against 4.3 us here (100 MB, 1 KB leaves, release, 2026-10-20).
interface Node {
	text: string;
	children: Node[];
	sizes: int32[];
	lines: int32[];
	bytes: int32;
	breaks: int32;
	height: int32;
}

function breaksIn(text: string): int32 {
	const bytes = text.asBytes();
	let count = 0;
	for (let i = 0; i < bytes.length; i++) {
		if (bytes[i] == NEWLINE) { count += 1; }
	}
	return count;
}

function leaf(text: string, breaks: int32): Node {
	return { text, children: [], sizes: [], lines: [], bytes: text.byteLength, breaks, height: 0 };
}

function leafOf(text: string): Node {
	return leaf(text, breaksIn(text));
}

function branchOf(children: Node[]): Node {
	const sizes: int32[] = [];
	const lines: int32[] = [];
	let bytes = 0;
	let breaks = 0;
	for (let i = 0; i < children.length; i++) {
		const child = children[i];
		sizes.push(child.bytes);
		lines.push(child.breaks);
		bytes += child.bytes;
		breaks += child.breaks;
	}
	return { text: "", children, sizes, lines, bytes, breaks, height: children[0].height + 1 };
}

function isContinuation(text: string, at: int32): boolean {
	return (text.byteAt(at) & 0xC0) == 0x80;
}

function leafFrom(bytes: Readonly<Span<uint8>>, from: int32, to: int32, crlf: boolean): Node {
	const out: uint8[] = [];
	let breaks = 0;
	for (let i = from; i < to; i++) {
		const byte = bytes[i];
		if (byte == NEWLINE) { breaks += 1; }
		if (!(crlf && byte == RETURN && i + 1 < to && bytes[i + 1] == NEWLINE)) { out.push(byte); }
	}
	return leaf(out.asString(), breaks);
}

function leavesOf(text: string, crlf: boolean): Node[] {
	const total = text.byteLength;
	if (total == 0) { return []; }
	if (total <= LEAF_MAX && !crlf) { return [leafOf(text)]; }
	const bytes = text.asBytes();
	const count = (total + LEAF_MAX - SPLIT_SLACK - 1) / (LEAF_MAX - SPLIT_SLACK);
	const base = total / count;
	const extra = total % count;
	const out: Node[] = [];
	let target = 0;
	let at = 0;
	for (let k = 1; k <= count; k++) {
		target += base + (k <= extra ? 1 : 0);
		let end = target;
		while (end > at && end < total && (bytes[end] & 0xC0) == 0x80) { end -= 1; }
		if (crlf && end > at && end < total && bytes[end - 1] == RETURN) { end -= 1; }
		if (end == at) { continue; }
		out.push(leafFrom(bytes, at, end, crlf));
		at = end;
	}
	return out;
}

function grouped(nodes: Node[]): Node[] {
	const count = nodes.length as int32;
	const parents = (count + BRANCH_MAX - 1) / BRANCH_MAX;
	const out: Node[] = [];
	let at = 0;
	for (let k = 1; k <= parents; k++) {
		const end = at + count / parents + (k <= count % parents ? 1 : 0);
		out.push(branchOf(nodes.slice(at, end)));
		at = end;
	}
	return out;
}

function underfull(n: Node): boolean {
	return n.height == 0 ? n.bytes < LEAF_MIN : (n.children.length as int32) < BRANCH_MIN;
}

function merged(a: Node, b: Node): Node[] {
	if (a.height > 0) { return grouped(rebalanced(a.children.concat(b.children))); }
	return leavesOf(a.text + b.text, false);
}

function rebalanced(nodes: Span<Node>): Node[] {
	const out: Node[] = [];
	for (let k = 0; k < nodes.length; k++) {
		const node = nodes[k];
		const last = out.length - 1;
		if (last >= 0 && (underfull(node) || underfull(out[last]))) {
			pushAll(out, merged(out.pop(), node));
		} else {
			out.push(node);
		}
	}
	return out;
}

function pushAll(out: Node[], nodes: Span<Node>): void {
	for (let k = 0; k < nodes.length; k++) { out.push(nodes[k]); }
}

function replaced(node: Node, from: int32, to: int32, text: string): Node[] {
	if (node.height == 0) {
		const body = node.text;
		return leavesOf(body.byteSlice(0, from) + text + body.byteSlice(to, node.bytes), false);
	}
	const kids = node.children;
	const sizes = node.sizes;
	let i = 0;
	let start = 0;
	while (i + 1 < sizes.length && from > start + sizes[i]) {
		start += sizes[i];
		i += 1;
	}
	let j = i;
	let startJ = start;
	while (j + 1 < sizes.length && to > startJ + sizes[j]) {
		startJ += sizes[j];
		j += 1;
	}
	const out: Node[] = kids.slice(0, i);
	if (i == j) {
		pushAll(out, replaced(kids[i], from - start, to - start, text));
	} else {
		pushAll(out, replaced(kids[i], from - start, sizes[i], text));
		pushAll(out, replaced(kids[j], 0, to - startJ, ""));
	}
	pushAll(out, kids[j + 1..kids.length]);
	return grouped(rebalanced(out));
}

function rootOf(nodes: Node[]): Node {
	if (nodes.length == 0) { return leafOf(""); }
	let level = nodes;
	while (level.length > 1) { level = grouped(level); }
	let root = level[0];
	while (root.height > 0 && root.children.length == 1) { root = root.children[0]; }
	return root;
}

function collect(node: Node, from: int32, to: int32, out: string[]): void {
	if (node.height == 0) {
		out.push(from == 0 && to == node.bytes ? node.text : node.text.byteSlice(from, to));
		return;
	}
	let start = 0;
	for (let k = 0; k < node.sizes.length; k++) {
		const end = start + node.sizes[k];
		if (end > from && start < to) {
			collect(node.children[k], Math.max(from, start) - start, Math.min(to, end) - start, out);
		}
		if (end >= to) { return; }
		start = end;
	}
}

export class Rope {
	private root: Node;

	constructor(text: string) {
		this.root = rootOf(leavesOf(text, true));
	}

	length(): int32 { return this.root.bytes; }
	lineCount(): int32 { return this.root.breaks + 1; }
	height(): int32 { return this.root.height; }

	text(): string { return this.slice(0, this.length()); }

	slice(from: int32, to: int32): string {
		this.check(from, to, "slice");
		const out: string[] = [];
		collect(this.root, from, to, out);
		return out.length == 1 ? out[0] : out.join("");
	}

	byteAt(offset: int32): int32 {
		this.check(offset, offset + 1, "byteAt");
		let node = this.root;
		let at = offset;
		while (node.height > 0) {
			const sizes = node.sizes;
			let i = 0;
			while (at >= sizes[i]) {
				at -= sizes[i];
				i += 1;
			}
			node = node.children[i];
		}
		return node.text.byteAt(at);
	}

	lineStart(line: int32): int32 {
		const lines = this.lineCount();
		if (line < 0 || line >= lines) {
			throw new Error(`Rope.lineStart: line ${line} is outside 0..${lines - 1}`);
		}
		if (line == 0) { return 0; }
		let node = this.root;
		let left = line;
		let offset = 0;
		while (node.height > 0) {
			const breaks = node.lines;
			let i = 0;
			while (left > breaks[i]) {
				left -= breaks[i];
				offset += node.sizes[i];
				i += 1;
			}
			node = node.children[i];
		}
		let at = -1;
		for (let k = 0; k < left; k++) { at = node.text.byteIndexOf("\n", at + 1); }
		return offset + at + 1;
	}

	lineEnd(line: int32): int32 {
		return line + 1 < this.lineCount() ? this.lineStart(line + 1) - 1 : this.length();
	}

	line(line: int32): string {
		return this.slice(this.lineStart(line), this.lineEnd(line));
	}

	lineOf(offset: int32): int32 {
		this.check(offset, offset, "lineOf");
		let node = this.root;
		let at = offset;
		let line = 0;
		while (node.height > 0) {
			const sizes = node.sizes;
			let i = 0;
			while (i + 1 < sizes.length && at >= sizes[i]) {
				at -= sizes[i];
				line += node.lines[i];
				i += 1;
			}
			node = node.children[i];
		}
		let found = node.text.byteIndexOf("\n");
		while (found >= 0 && found < at) {
			line += 1;
			found = node.text.byteIndexOf("\n", found + 1);
		}
		return line;
	}

	replace(from: int32, to: int32, text: string): void {
		this.check(from, to, "replace");
		this.root = rootOf(replaced(this.root, from, to, text));
	}

	private check(from: int32, to: int32, who: string): void {
		const total = this.length();
		if (from < 0 || from > to || to > total) {
			throw new Error(`Rope.${who}: range ${from}..${to} is outside 0..${total}`);
		}
	}
}

function nextSeed(seed: uint32): uint32 {
	let x = seed;
	x ^= x << 13;
	x ^= x >>> 17;
	x ^= x << 5;
	return x;
}

function sampleText(seed: uint32, bytes: int32): string {
	const alphabet = ["a", "b", " ", "\n", "é", "😀", "xyz", "\n\n", "tiếng"];
	const parts: string[] = [];
	let size = 0;
	let s = seed;
	while (size < bytes) {
		s = nextSeed(s);
		const piece = alphabet[(s % (alphabet.length as uint32)) as int32];
		parts.push(piece);
		size += piece.byteLength;
	}
	return parts.join("");
}

function boundaryAt(text: string, at: int32): int32 {
	let b = at;
	while (b > 0 && b < text.byteLength && isContinuation(text, b)) { b -= 1; }
	return b;
}

function linesMatch(rope: Rope, model: string): boolean {
	const lines = model.split("\n");
	if (rope.lineCount() != (lines.length as int32)) { return false; }
	for (let i = 0; i < lines.length; i++) {
		if (rope.line(i as int32) != lines[i]) { return false; }
	}
	return true;
}

function balanced(node: Node, isRoot: boolean): boolean {
	if (node.height == 0) { return node.bytes <= LEAF_MAX && (isRoot || node.bytes > 0); }
	if ((node.children.length as int32) > BRANCH_MAX) { return false; }
	if (!isRoot && (node.children.length as int32) < 2) { return false; }
	for (let k = 0; k < node.children.length; k++) {
		const c = node.children[k];
		if (node.sizes[k] != c.bytes || node.lines[k] != c.breaks) { return false; }
		if (c.height != node.height - 1 || !balanced(c, false)) { return false; }
	}
	return true;
}

function textOf(node: Node): string {
	const out: string[] = [];
	collect(node, 0, node.bytes, out);
	return out.join("");
}

test "an empty rope has one empty line" {
	const r = new Rope("");
	assert r.length() == 0;
	assert r.lineCount() == 1;
	assert r.line(0) == "";
	assert r.lineOf(0) == 0;
}

test "offsets count UTF-8 bytes" {
	const r = new Rope("tiếng\n😀x");
	assert r.length() == 13;
	assert r.lineStart(1) == 8;
	assert r.lineEnd(0) == 7;
	assert r.byteAt(12) == 120;
	assert r.slice(8, 12) == "😀";
	assert r.lineOf(7) == 0;
	assert r.lineOf(8) == 1;
}

test "lines and their offsets" {
	const r = new Rope("ab\ncd\n\nef");
	assert r.lineCount() == 4;
	assert r.line(1) == "cd";
	assert r.line(2) == "";
	assert r.lineStart(3) == 7;
	assert r.lineEnd(0) == 2;
	assert r.lineOf(2) == 0;
	assert r.lineOf(3) == 1;
	assert r.lineOf(9) == 3;
}

test "a large text builds a balanced tree and reads back whole" {
	const text = sampleText(7, 200 * LEAF_MAX);
	const r = new Rope(text);
	assert r.height() >= 2;
	assert r.text() == text;
	assert r.length() == text.byteLength;
	assert linesMatch(r, text);
}

test "a leaf boundary never splits a code point" {
	const parts: string[] = [];
	for (let i = 0; i < 1500; i++) { parts.push("😀é"); }
	const text = parts.join("");
	const r = new Rope(text);
	assert r.text() == text;
	assert r.slice(6 * 400, 6 * 402) == "😀é😀é";
}

test "building turns CRLF into LF, across leaf boundaries too" {
	const parts: string[] = [];
	for (let i = 0; i < 3000; i++) { parts.push("ab\r\n"); }
	const r = new Rope(parts.join(""));
	assert r.length() == 9000;
	assert r.lineCount() == 3001;
	assert r.line(2999) == "ab";
	assert r.text().byteIndexOf("\r") < 0;
}

test "random edits agree with a plain string and keep the tree balanced" {
	let seed: uint32 = 2026;
	let model = sampleText(3, 40 * LEAF_MAX);
	let root = rootOf(leavesOf(model, false));
	for (let step = 0; step < 400; step++) {
		seed = nextSeed(seed);
		const total = model.byteLength as uint32;
		const from = boundaryAt(model, (seed % (total + 1)) as int32);
		seed = nextSeed(seed);
		const span = step % 7 == 0 ? (seed % (10 * LEAF_MAX as uint32)) as int32 : (seed % 40) as int32;
		const to = boundaryAt(model, Math.min(from + span, total as int32));
		seed = nextSeed(seed);
		const size = step % 11 == 0 ? (seed % (6 * LEAF_MAX as uint32)) as int32 : (seed % 8) as int32;
		const insert = step % 3 == 0 ? "" : sampleText(seed, size);
		root = rootOf(replaced(root, from, to, insert));
		model = model.byteSlice(0, from) + insert + model.byteSlice(to, model.byteLength);
		assert root.bytes == model.byteLength;
		assert balanced(root, true);
	}
	assert textOf(root) == model;
	assert root.breaks == breaksIn(model);
}

test "rope queries agree with a plain string after edits" {
	let model = sampleText(13, 60000);
	const r = new Rope(model);
	const edits = [[100, 5000, 7], [30000, 30000, 2000], [0, 10, 3], [40000, 52000, 0]];
	for (const e of edits) {
		const from = boundaryAt(model, e[0] as int32);
		const to = boundaryAt(model, Math.min(e[1] as int32, model.byteLength));
		const insert = sampleText(from as uint32 + 1, e[2] as int32);
		r.replace(from, to, insert);
		model = model.byteSlice(0, from) + insert + model.byteSlice(to, model.byteLength);
	}
	assert r.text() == model;
	assert linesMatch(r, model);
	const probe = boundaryAt(model, model.byteLength / 3);
	assert r.lineOf(probe) == breaksIn(model.byteSlice(0, probe));
	for (let k = 0; k < 50; k++) {
		const at = (k * 397) % model.byteLength;
		assert r.byteAt(at) == model.byteAt(at);
	}
}

test "a kept root still reads the text from before an edit" {
	const text = sampleText(9, 50000);
	const before = rootOf(leavesOf(text, false));
	const after = rootOf(replaced(before, 100, 40000, "x"));
	assert textOf(before) == text;
	assert after.bytes == text.byteLength - 39900 + 1;
}

test "deleting everything leaves one empty leaf" {
	const r = new Rope(sampleText(5, 30000));
	r.replace(0, r.length(), "");
	assert r.length() == 0;
	assert r.lineCount() == 1;
	assert r.height() == 0;
}
