import { Document } from "./document";
import { isTrail } from "../text/clusters";

const NO_NUMBER: int32 = -1;
const DIGIT_0: int32 = "0".code;
const DIGIT_9: int32 = "9".code;
const DELIMITER = ":";

export struct LineTarget {
	line: int32;
	character: int32;
	relative: int32;
}

function numberOf(text: string): int32 {
	const digits = text.trim();
	if (digits.byteLength == 0) { return NO_NUMBER; }
	let n = 0;
	for (let k = 0; k < digits.byteLength; k++) {
		const b = digits.byteAt(k);
		if (b < DIGIT_0 || b > DIGIT_9) { return NO_NUMBER; }
		n = n * 10 + (b - DIGIT_0);
	}
	return n;
}

function directionOf(b: int32): int32 {
	return b == "+".code || b == "f".code || b == "F".code ? 1
		: b == "-".code || b == "b".code || b == "B".code ? -1 : 0;
}

export function lineTarget(query: string, currentLine: int32): LineTarget | null {
	const text = query.trim();
	let direction = 0;
	let from = 0;
	while (from < text.byteLength && directionOf(text.byteAt(from)) != 0) {
		direction = directionOf(text.byteAt(from));
		from += 1;
	}
	if (direction != 0) {
		const rest = text.byteSlice(from, text.byteLength);
		const cut = rest.byteIndexOf(DELIMITER);
		const n = numberOf(cut < 0 ? rest : rest.byteSlice(0, cut));
		if (n == NO_NUMBER) { return null; }
		return { line: Math.max(0, currentLine + direction * n), character: 0, relative: direction * n };
	}
	const cut = text.byteIndexOf(DELIMITER);
	const line = numberOf(cut < 0 ? text : text.byteSlice(0, cut));
	if (line == NO_NUMBER) { return null; }
	const character = cut < 0 ? 0 : numberOf(text.byteSlice(cut + 1, text.byteLength));
	return { line, character: Math.max(0, character), relative: 0 };
}

export function targetLine(this doc: Document, t: LineTarget): int32 {
	return Math.min(Math.max(0, t.line - 1), doc.lineCount() - 1);
}

export function targetOffset(this doc: Document, t: LineTarget): int32 {
	const line = doc.targetLine(t);
	const end = doc.lineEnd(line);
	let at = doc.lineStart(line);
	for (let left = t.character - 1; left > 0 && at < end; left--) {
		at += 1;
		while (at < end && isTrail(doc.byteAt(at))) { at += 1; }
	}
	return at;
}

function offsetFor(text: string, query: string, current: int32 = 1): int32 {
	const t = lineTarget(query, current);
	return t === null ? NO_NUMBER : new Document(text).targetOffset(t as LineTarget);
}

test "a line and an optional character, both counted from one" {
	assert offsetFor("ab\ncd\nef", "2") == 3;
	assert offsetFor("ab\ncd\nef", " 3:2 ") == 7;
	assert offsetFor("ab\nđệx", "2:3") == 8;
	assert offsetFor("ab\ncd\nef", "2:") == 3;
}

test "a line or character past the end stops at the end, and line zero is the first" {
	assert offsetFor("ab\ncd", "9") == 3;
	assert offsetFor("ab\ncd", "1:9") == 2;
	assert offsetFor("ab\ncd", "0") == 0;
}

test "a sign or f and b move from the current line" {
	assert offsetFor("a\nb\nc\nd", "+2", 1) == 4;
	assert offsetFor("a\nb\nc\nd", "b1", 3) == 2;
	assert offsetFor("a\nb\nc\nd", "-9", 3) == 0;
	const t = lineTarget("f2", 3) as LineTarget;
	assert t.line == 5 && t.relative == 2;
}

test "anything else is no target" {
	assert lineTarget("", 1) === null;
	assert lineTarget("x", 1) === null;
	assert lineTarget("1x", 1) === null;
	assert lineTarget("+", 1) === null;
}
