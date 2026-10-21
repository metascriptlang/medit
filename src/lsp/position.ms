import { Rope } from "../text/rope";
import { Document } from "../model/document";

export struct Position {
	line: int32;
	character: int32;
}

export struct Range {
	start: Position;
	end: Position;
}

function unitsOf(lead: int32): int32 {
	if (lead < 0x80) { return 1; }
	if (lead < 0xC0) { return 0; }
	return lead < 0xF0 ? 1 : 2;
}

export function utf16Length(bytes: string): int32 {
	let units = 0;
	for (let k = 0; k < bytes.byteLength; k++) { units += unitsOf(bytes.byteAt(k)); }
	return units;
}

export function byteColumn(line: string, character: int32): int32 {
	let units = 0;
	let k = 0;
	while (k < line.byteLength) {
		const next = units + unitsOf(line.byteAt(k));
		if (next > character) { break; }
		units = next;
		k += 1;
		while (k < line.byteLength && unitsOf(line.byteAt(k)) == 0) { k += 1; }
	}
	return k;
}

export function positionIn(rope: Rope, offset: int32): Position {
	const line = rope.lineOf(offset);
	return { line, character: utf16Length(rope.slice(rope.lineStart(line), offset)) };
}

export function offsetIn(rope: Rope, p: Position): int32 {
	if (p.line < 0) { return 0; }
	if (p.line >= rope.lineCount()) { return rope.length(); }
	const start = rope.lineStart(p.line);
	return start + byteColumn(rope.slice(start, rope.lineEnd(p.line)), Math.max(0, p.character));
}

export function positionOf(this doc: Document, offset: int32): Position {
	const line = doc.lineOf(offset);
	return { line, character: utf16Length(doc.slice(doc.lineStart(line), offset)) };
}

export function offsetOf(this doc: Document, p: Position): int32 {
	if (p.line < 0) { return 0; }
	if (p.line >= doc.lineCount()) { return doc.length(); }
	const start = doc.lineStart(p.line);
	return start + byteColumn(doc.line(p.line), Math.max(0, p.character));
}

test "UTF-16 counts one unit below U+10000 and two above it" {
	assert utf16Length("aé€") == 3;
	assert utf16Length("a😀b") == 4;
	assert utf16Length("") == 0;
}

test "a UTF-16 column maps back to the byte column of its character" {
	const line = "aé😀b";
	assert byteColumn(line, 0) == 0;
	assert byteColumn(line, 1) == 1;
	assert byteColumn(line, 2) == 3;
	assert byteColumn(line, 3) == 3;
	assert byteColumn(line, 4) == 7;
	assert byteColumn(line, 5) == 8;
	assert byteColumn(line, 99) == 8;
}

test "positions and offsets round-trip in a document, clamped at its ends" {
	const d = new Document("ab\ncé😀d\n");
	const p = d.positionOf(10);
	assert p.line == 1 && p.character == 4;
	assert d.offsetOf(p) == 10;
	assert d.offsetOf({ line: 1, character: 3 }) == 6;
	assert d.offsetOf({ line: 1, character: 50 }) == 11;
	assert d.offsetOf({ line: 7, character: 0 }) == d.length();
	assert d.offsetOf({ line: -1, character: 3 }) == 0;
	const r = d.snapshot();
	assert positionIn(r, 10).character == 4 && offsetIn(r, p) == 10;
	assert offsetIn(r, { line: 2, character: 0 }) == 12;
}
