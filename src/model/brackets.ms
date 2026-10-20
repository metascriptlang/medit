import { Document } from "./document";
import { backToBoundary, forwardToBoundary } from "./find";

const BRACKET_REACH: int32 = 64 * 1024;
const NONE: int32 = -1;

export struct BracketPair {
	open: int32;
	close: int32;
}

function openerKind(b: int32): int32 {
	return b == "(".code ? 0 : b == "[".code ? 1 : b == "{".code ? 2 : NONE;
}

function closerKind(b: int32): int32 {
	return b == ")".code ? 0 : b == "]".code ? 1 : b == "}".code ? 2 : NONE;
}

function closeOf(bytes: Readonly<Span<uint8>>, open: int32): int32 {
	const pending: int32[] = [];
	for (let k = open + 1; k < bytes.length; k++) {
		const b = bytes[k] as int32;
		if (openerKind(b) != NONE) { pending.push(openerKind(b)); continue; }
		const c = closerKind(b);
		if (c == NONE) { continue; }
		if (pending.length == 0) { return c == openerKind(bytes[open] as int32) ? k : NONE; }
		if (pending[pending.length - 1] != c) { return NONE; }
		const _done = pending.pop();
	}
	return NONE;
}

function openOf(bytes: Readonly<Span<uint8>>, close: int32): int32 {
	const pending: int32[] = [];
	for (let k = close - 1; k >= 0; k--) {
		const b = bytes[k] as int32;
		if (closerKind(b) != NONE) { pending.push(closerKind(b)); continue; }
		const o = openerKind(b);
		if (o == NONE) { continue; }
		if (pending.length == 0) { return o == closerKind(bytes[close] as int32) ? k : NONE; }
		if (pending[pending.length - 1] != o) { return NONE; }
		const _done = pending.pop();
	}
	return NONE;
}

function smaller(best: BracketPair | null, open: int32, close: int32): BracketPair {
	if (best !== null && (best as BracketPair).close - (best as BracketPair).open <= close - open) {
		return best as BracketPair;
	}
	return { open, close };
}

function enclosingIn(bytes: Readonly<Span<uint8>>, from: int32, to: int32): BracketPair | null {
	let best: BracketPair | null = null;
	if (from < bytes.length && openerKind(bytes[from] as int32) != NONE) {
		const close = closeOf(bytes, from);
		if (close != NONE && close + 1 >= to) { best = smaller(best, from, close); }
	}
	if (to > 0 && closerKind(bytes[to - 1] as int32) != NONE) {
		const open = openOf(bytes, to - 1);
		if (open != NONE && open <= from) { best = smaller(best, open, to - 1); }
	}
	const pending: int32[] = [];
	for (let k = from - 1; k >= 0; k--) {
		const b = bytes[k] as int32;
		if (closerKind(b) != NONE) { pending.push(closerKind(b)); continue; }
		const o = openerKind(b);
		if (o == NONE) { continue; }
		if (pending.length > 0) {
			if (pending[pending.length - 1] != o) { break; }
			const _done = pending.pop();
			continue;
		}
		const close = closeOf(bytes, k);
		if (close != NONE && close + 1 >= to) {
			best = smaller(best, k, close);
			break;
		}
	}
	return best;
}

export function enclosingBrackets(this doc: Document, from: int32, to: int32): BracketPair | null {
	if (to - from > BRACKET_REACH) { return null; }
	const lo = doc.backToBoundary(Math.max(0, from - BRACKET_REACH));
	const hi = doc.forwardToBoundary(Math.min(doc.length(), to + BRACKET_REACH));
	const text = doc.slice(lo, hi);
	const found = enclosingIn(text.asBytes(), from - lo, to - lo);
	if (found === null) { return null; }
	const p = found as BracketPair;
	return { open: p.open + lo, close: p.close + lo };
}

function pairAt(text: string, from: int32, to: int32 = from): string {
	const p = new Document(text).enclosingBrackets(from, to);
	return p === null ? "none" : `${(p as BracketPair).open},${(p as BracketPair).close}`;
}

test "the innermost pair around the caret, touching or inside it" {
	assert pairAt("f(a[b]c)", 4) == "3,5";
	assert pairAt("f(a[b]c)", 3) == "3,5";
	assert pairAt("f(a[b]c)", 6) == "3,5";
	assert pairAt("f(a[b]c)", 7) == "1,7";
	assert pairAt("f(a[b]c)", 8) == "1,7";
	assert pairAt("f(a[b]c)", 1) == "1,7";
	assert pairAt("f(a[b]c)", 0) == "none";
}

test "between a closer and an opener the smaller pair wins" {
	assert pairAt("(ab)(c)", 4) == "4,6";
	assert pairAt("(a)(bc)", 3) == "0,2";
}

test "a selection takes the pair around all of it" {
	assert pairAt("{(a) b}", 1, 5) == "0,6";
	assert pairAt("{(a) b}", 1, 4) == "1,3";
}

test "unbalanced or mismatched brackets give no pair" {
	assert pairAt("(a]", 1) == "none";
	assert pairAt("(a", 1) == "none";
	assert pairAt("a)", 1) == "none";
	assert pairAt("([a)]", 2) == "none";
}

test "a pair reaching past the scan window is not found" {
	const far = "(" + "x".repeat(BRACKET_REACH + 1) + ")";
	assert pairAt(far, 1) == "none";
	assert pairAt(far, 0) == "none";
	const near = "(" + "x".repeat(BRACKET_REACH - 2) + ")";
	assert pairAt(near, 1) == `0,${BRACKET_REACH - 1}`;
}
