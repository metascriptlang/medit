export const CHUNK_MAX: int32 = 1024;
const CHUNK_MIN: int32 = 256;
const NEWLINE: int32 = 10;

struct Chunk {
	text: string;
	units: int32;
	breaks: int32;
}

function isHighSurrogate(code: int32): boolean {
	return code >= 0xD800 && code <= 0xDBFF;
}

function breaksIn(text: string): int32 {
	let count = 0;
	let at = text.indexOf("\n");
	while (at >= 0) {
		count += 1;
		at = text.indexOf("\n", at + 1);
	}
	return count;
}

function chunkOf(text: string): Chunk {
	return { text, units: text.length as int32, breaks: breaksIn(text) };
}

function piecesOf(text: string): Chunk[] {
	const pieces: Chunk[] = [];
	const total = text.length as int32;
	let start = 0;
	while (start < total) {
		let end = Math.min(start + CHUNK_MAX, total);
		if (end < total && isHighSurrogate(text.charCodeAt(end - 1))) { end -= 1; }
		pieces.push(chunkOf(text.slice(start, end)));
		start = end;
	}
	return pieces;
}

export class Rope {
	private chunks: Chunk[];
	private unitsBefore: int32[];
	private breaksBefore: int32[];
	private clean: int32;

	constructor(text: string) {
		this.chunks = piecesOf(text);
		if (this.chunks.length == 0) { this.chunks.push(chunkOf("")); }
		this.unitsBefore = [0];
		this.breaksBefore = [0];
		this.clean = 0;
	}

	length(): int32 {
		this.summarize();
		return this.unitsBefore[this.chunks.length];
	}

	lineCount(): int32 {
		this.summarize();
		return this.breaksBefore[this.chunks.length] + 1;
	}

	text(): string {
		let all = "";
		for (const c of this.chunks) { all += c.text; }
		return all;
	}

	slice(from: int32, to: int32): string {
		this.check(from, to, "slice");
		if (from == to) { return ""; }
		const a = this.chunkAt(from);
		const b = this.chunkAt(to);
		const fromInA = from - this.unitsBefore[a];
		if (a == b) { return this.chunks[a].text.slice(fromInA, to - this.unitsBefore[a]); }
		let out = this.chunks[a].text.slice(fromInA);
		for (let i = a + 1; i < b; i++) { out += this.chunks[i].text; }
		return out + this.chunks[b].text.slice(0, to - this.unitsBefore[b]);
	}

	lineStart(line: int32): int32 {
		const lines = this.lineCount();
		if (line < 0 || line >= lines) {
			throw new Error(`Rope.lineStart: line ${line} is outside 0..${lines - 1}`);
		}
		if (line == 0) { return 0; }
		const i = this.chunkHoldingBreak(line);
		const text = this.chunks[i].text;
		let at = -1;
		for (let k = this.breaksBefore[i]; k < line; k++) { at = text.indexOf("\n", at + 1); }
		return this.unitsBefore[i] + at + 1;
	}

	lineEnd(line: int32): int32 {
		return line + 1 < this.lineCount() ? this.lineStart(line + 1) - 1 : this.length();
	}

	line(line: int32): string {
		return this.slice(this.lineStart(line), this.lineEnd(line));
	}

	lineOf(offset: int32): int32 {
		this.check(offset, offset, "lineOf");
		const i = this.chunkAt(offset);
		const text = this.chunks[i].text;
		const inChunk = offset - this.unitsBefore[i];
		let line = this.breaksBefore[i];
		let at = text.indexOf("\n");
		while (at >= 0 && at < inChunk) {
			line += 1;
			at = text.indexOf("\n", at + 1);
		}
		return line;
	}

	codeAt(offset: int32): int32 {
		this.check(offset, offset + 1, "codeAt");
		const i = this.chunkAt(offset);
		return this.chunks[i].text.charCodeAt(offset - this.unitsBefore[i]);
	}

	replace(from: int32, to: int32, text: string): void {
		this.check(from, to, "replace");
		let a = this.chunkAt(from);
		let b = this.chunkAt(to);
		let merged = this.chunks[a].text.slice(0, from - this.unitsBefore[a]) +
			text +
			this.chunks[b].text.slice(to - this.unitsBefore[b]);
		if ((merged.length as int32) < CHUNK_MIN && b + 1 < this.chunks.length) {
			b += 1;
			merged += this.chunks[b].text;
		}
		if ((merged.length as int32) < CHUNK_MIN && a > 0) {
			a -= 1;
			merged = this.chunks[a].text + merged;
		}
		const pieces = piecesOf(merged);
		if (pieces.length == 0 && a == 0 && b + 1 == this.chunks.length) { pieces.push(chunkOf("")); }
		this.insertChunks(a, b + 1, pieces);
		this.clean = Math.min(this.clean, a);
	}

	private insertChunks(from: int32, to: int32, pieces: Chunk[]): void {
		const next: Chunk[] = [];
		for (let i = 0; i < from; i++) { next.push(this.chunks[i]); }
		for (const p of pieces) { next.push(p); }
		for (let i = to; i < this.chunks.length; i++) { next.push(this.chunks[i]); }
		this.chunks = next;
	}

	chunkCount(): int32 {
		return this.chunks.length as int32;
	}

	private summarize(): void {
		const n = this.chunks.length as int32;
		if (this.clean >= n && this.unitsBefore.length == n + 1) { return; }
		this.unitsBefore.setLength(n + 1);
		this.breaksBefore.setLength(n + 1);
		for (let i = this.clean; i < n; i++) {
			this.unitsBefore[i + 1] = this.unitsBefore[i] + this.chunks[i].units;
			this.breaksBefore[i + 1] = this.breaksBefore[i] + this.chunks[i].breaks;
		}
		this.clean = n;
	}

	private check(from: int32, to: int32, who: string): void {
		const total = this.length();
		if (from < 0 || from > to || to > total) {
			throw new Error(`Rope.${who}: range ${from}..${to} is outside 0..${total}`);
		}
	}

	private chunkAt(offset: int32): int32 {
		let low = 0;
		let high = (this.chunks.length as int32) - 1;
		while (low < high) {
			const mid = (low + high + 1) / 2;
			if (this.unitsBefore[mid] <= offset) { low = mid; } else { high = mid - 1; }
		}
		return low;
	}

	private chunkHoldingBreak(line: int32): int32 {
		let low = 0;
		let high = (this.chunks.length as int32) - 1;
		while (low < high) {
			const mid = (low + high) / 2;
			if (this.breaksBefore[mid + 1] >= line) { high = mid; } else { low = mid + 1; }
		}
		return low;
	}
}

function nextSeed(seed: uint32): uint32 {
	let x = seed;
	x ^= x << 13;
	x ^= x >>> 17;
	x ^= x << 5;
	return x;
}

function sampleText(seed: uint32, units: int32): string {
	const alphabet = ["a", "b", " ", "\n", "é", "😀", "xyz", "\n\n", "tiếng"];
	let out = "";
	let s = seed;
	while ((out.length as int32) < units) {
		s = nextSeed(s);
		out += alphabet[(s % (alphabet.length as uint32)) as int32];
	}
	return out;
}

function linesMatch(rope: Rope, model: string): boolean {
	const lines = model.split("\n");
	if (rope.lineCount() != (lines.length as int32)) { return false; }
	for (let i = 0; i < lines.length; i++) {
		if (rope.line(i as int32) != lines[i]) { return false; }
	}
	return true;
}

test "an empty rope has one empty line" {
	const r = new Rope("");
	assert r.length() == 0;
	assert r.lineCount() == 1;
	assert r.line(0) == "";
	assert r.lineOf(0) == 0;
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

test "a long text splits into chunks and reads back whole" {
	const text = sampleText(7, 5000);
	const r = new Rope(text);
	assert r.chunkCount() > 4;
	assert r.text() == text;
	assert r.length() == (text.length as int32);
	assert linesMatch(r, text);
}

test "a chunk boundary never splits a surrogate pair" {
	let text = "";
	for (let i = 0; i < 1500; i++) { text += "😀"; }
	const r = new Rope(text);
	assert r.slice(1022, 1026) == "😀😀";
	assert r.text() == text;
}

test "replace inserts, deletes and spans chunks" {
	const text = sampleText(11, 3000);
	const r = new Rope(text);
	r.replace(10, 10, "INSERT\n");
	let model = text.slice(0, 10) + "INSERT\n" + text.slice(10);
	assert r.text() == model;
	r.replace(500, 2500, "");
	model = model.slice(0, 500) + model.slice(2500);
	assert r.text() == model;
	assert linesMatch(r, model);
}

test "random edits agree with a plain string" {
	let seed: uint32 = 2026;
	let model = sampleText(3, 4000);
	const r = new Rope(model);
	for (let step = 0; step < 300; step++) {
		seed = nextSeed(seed);
		const total = model.length as uint32;
		let from = (seed % (total + 1)) as int32;
		seed = nextSeed(seed);
		let to = Math.min(from + ((seed % 700) as int32), total as int32);
		if (from > 0 && isHighSurrogate(model.charCodeAt(from - 1))) { from -= 1; }
		if (to > 0 && to < (total as int32) && isHighSurrogate(model.charCodeAt(to - 1))) { to += 1; }
		seed = nextSeed(seed);
		const insert = step % 3 == 0 ? "" : sampleText(seed, (seed % 1500) as int32);
		r.replace(from, to, insert);
		model = model.slice(0, from) + insert + model.slice(to);
		assert r.length() == (model.length as int32);
	}
	assert r.text() == model;
	assert linesMatch(r, model);
	const probe = (model.length as int32) / 3;
	assert r.lineOf(probe) == (model.slice(0, probe).split("\n").length as int32) - 1;
}

test "deleting everything leaves one empty chunk" {
	const r = new Rope(sampleText(5, 3000));
	r.replace(0, r.length(), "");
	assert r.length() == 0;
	assert r.lineCount() == 1;
	assert r.chunkCount() == 1;
}
