const PERCENT: int32 = 37;
const OPEN: int32 = 91;
const CLOSE: int32 = 93;
const CARET: int32 = 94;
const DOLLAR: int32 = 36;
const DOT: int32 = 46;
const DASH: int32 = 45;

function at(b: Readonly<Span<uint8>>, i: int32): int32 {
	return i < (b.length as int32) ? b[i] as int32 : -1;
}

function inClass(c: int32, cl: int32): boolean {
	const lower = cl | 0x20;
	let hit = false;
	if (lower == 97) { hit = (c | 0x20) >= 97 && (c | 0x20) <= 122; }
	else if (lower == 100) { hit = c >= 48 && c <= 57; }
	else if (lower == 108) { hit = c >= 97 && c <= 122; }
	else if (lower == 117) { hit = c >= 65 && c <= 90; }
	else if (lower == 115) { hit = c == 32 || (c >= 9 && c <= 13); }
	else if (lower == 119) { hit = inClass(c, 97) || inClass(c, 100); }
	else if (lower == 120) { hit = inClass(c, 100) || ((c | 0x20) >= 97 && (c | 0x20) <= 102); }
	else if (lower == 112) { hit = c > 32 && c < 127 && !inClass(c, 119); }
	else if (lower == 99) { hit = c < 32 || c == 127; }
	else { return c == cl; }
	return cl == lower ? hit : !hit;
}

function classEnd(p: Readonly<Span<uint8>>, i: int32): int32 {
	const c = at(p, i);
	if (c == PERCENT) {
		if (i + 1 >= (p.length as int32)) { throw new Error("lua pattern ends with %"); }
		const next = at(p, i + 1);
		if (next == 98 || next == 102) { throw new Error(`lua pattern %${String.fromCharCode(next)} is not supported`); }
		return i + 2;
	}
	if (c == 40 || c == 41) { throw new Error("lua pattern captures are not supported"); }
	if (c != OPEN) { return i + 1; }
	let k = i + 1;
	if (at(p, k) == CARET) { k += 1; }
	k += 1;
	while (at(p, k) != CLOSE) {
		if (k >= (p.length as int32)) { throw new Error("lua pattern has an unclosed ["); }
		k += at(p, k) == PERCENT ? 2 : 1;
	}
	return k + 1;
}

function inSet(c: int32, p: Readonly<Span<uint8>>, from: int32, close: int32): boolean {
	let k = from + 1;
	const negated = at(p, k) == CARET;
	if (negated) { k += 1; }
	while (k < close) {
		if (at(p, k) == PERCENT) {
			if (inClass(c, at(p, k + 1))) { return !negated; }
			k += 2;
		} else if (at(p, k + 1) == DASH && k + 2 < close) {
			if (c >= at(p, k) && c <= at(p, k + 2)) { return !negated; }
			k += 3;
		} else {
			if (c == at(p, k)) { return !negated; }
			k += 1;
		}
	}
	return negated;
}

function single(c: int32, p: Readonly<Span<uint8>>, i: int32, end: int32): boolean {
	if (c < 0) { return false; }
	const pc = at(p, i);
	if (pc == DOT) { return true; }
	if (pc == PERCENT) { return inClass(c, at(p, i + 1)); }
	if (pc == OPEN) { return inSet(c, p, i, end - 1); }
	return c == pc;
}

function matchFrom(s: Readonly<Span<uint8>>, si: int32, p: Readonly<Span<uint8>>, pi: int32): int32 {
	let i = si;
	let k = pi;
	const plen = p.length as int32;
	while (k < plen) {
		if (at(p, k) == DOLLAR && k + 1 == plen) { return i == (s.length as int32) ? i : -1; }
		const end = classEnd(p, k);
		const q = at(p, end);
		if (q == 63) {
			if (single(at(s, i), p, k, end)) {
				const r = matchFrom(s, i + 1, p, end + 1);
				if (r >= 0) { return r; }
			}
			k = end + 1;
		} else if (q == 42 || q == 43) {
			let n = 0;
			while (single(at(s, i + n), p, k, end)) { n += 1; }
			const least = q == 43 ? 1 : 0;
			while (n >= least) {
				const r = matchFrom(s, i + n, p, end + 1);
				if (r >= 0) { return r; }
				n -= 1;
			}
			return -1;
		} else if (q == DASH) {
			while (true) {
				const r = matchFrom(s, i, p, end + 1);
				if (r >= 0) { return r; }
				if (!single(at(s, i), p, k, end)) { return -1; }
				i += 1;
			}
		} else {
			if (!single(at(s, i), p, k, end)) { return -1; }
			i += 1;
			k = end;
		}
	}
	return i;
}

export function luaMatches(text: string, pattern: string): boolean {
	const s = text.asBytes();
	const p = pattern.asBytes();
	const anchored = at(p, 0) == CARET;
	for (let si = 0; si <= (s.length as int32); si++) {
		if (matchFrom(s, si, p, anchored ? 1 : 0) >= 0) { return true; }
		if (anchored) { return false; }
	}
	return false;
}

test "anchors, classes and sets" {
	assert luaMatches("Foo", "^[A-Z]");
	assert !luaMatches("foo", "^[A-Z]");
	assert luaMatches("MAX_SIZE2", "^_*[A-Z][A-Z%d_]*$");
	assert luaMatches("__A", "^_*[A-Z][A-Z%d_]*$");
	assert !luaMatches("MaxSize", "^_*[A-Z][A-Z%d_]*$");
	assert luaMatches("onMount", "^on[A-Z]");
	assert !luaMatches("only", "^on[A-Z]");
	assert luaMatches("xx12", "%d+$");
	assert luaMatches("a.b", "a%.b");
	assert !luaMatches("axb", "a%.b");
}

test "greedy, lazy and optional repeats" {
	assert luaMatches("/** doc */", "^/[*][*][^*].*[*]/$");
	assert !luaMatches("/* note */", "^/[*][*][^*].*[*]/$");
	assert !luaMatches("/***/", "^/[*][*][^*].*[*]/$");
	assert luaMatches("ab", "^a-b$");
	assert luaMatches("colour", "^colou?r$");
	assert luaMatches("color", "^colou?r$");
	assert !luaMatches("x", "^%a%a");
}

test "an unsupported item is refused by name" {
	let refused = 0;
	try { const _m = luaMatches("x", "%b()"); } catch (e) { refused += 1; }
	try { const _n = luaMatches("x", "(x)"); } catch (e) { refused += 1; }
	assert refused == 2;
}
