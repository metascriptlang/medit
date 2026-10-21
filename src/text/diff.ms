export const DIFF_LIMIT: int32 = 1000;
const WORD_DIFF_BYTES: int32 = 512;
const WORD_DIFF_LINES: int32 = 8;
const NEWLINE: int32 = 10;

export struct Replace {
	from: int32;
	to: int32;
	text: string;
}

struct Hunk {
	oldFrom: int32;
	oldTo: int32;
	newFrom: int32;
	newTo: int32;
}

// Each line with its line break.
function lines(s: string): string[] {
	const out: string[] = [];
	const n = s.byteLength as int32;
	let from = 0;
	for (let k = 0; k < n; k++) {
		if (s.byteAt(k) == NEWLINE) {
			out.push(s.byteSlice(from, k + 1));
			from = k + 1;
		}
	}
	if (from < n) { out.push(s.byteSlice(from, n)); }
	return out;
}

const SPACE: int32 = 0;
const WORD: int32 = 1;
const PUNCTUATION: int32 = 2;

function kindOf(b: int32): int32 {
	if (b == 32 || (b >= 9 && b <= 13)) { return SPACE; }
	const word = b >= 0x80 || b == 95 || (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122);
	return word ? WORD : PUNCTUATION;
}

// Runs of word bytes, of whitespace, and of one repeated punctuation byte.
function words(s: string): string[] {
	const out: string[] = [];
	const n = s.byteLength as int32;
	let from = 0;
	for (let k = 1; k < n; k++) {
		const kind = kindOf(s.byteAt(k));
		const before = kindOf(s.byteAt(k - 1));
		if (kind != before || (kind == PUNCTUATION && s.byteAt(k) != s.byteAt(k - 1))) {
			out.push(s.byteSlice(from, k));
			from = k;
		}
	}
	if (from < n) { out.push(s.byteSlice(from, n)); }
	return out;
}

// The token ranges where a and b differ, in order, from the shortest edit script; null when
// that script is longer than `limit` tokens.
function hunks(a: string[], b: string[], limit: int32): Hunk[] | null {
	let lo = 0;
	const minLength = Math.min(a.length, b.length) as int32;
	while (lo < minLength && a[lo] == b[lo]) { lo += 1; }
	let n = a.length as int32;
	let m = b.length as int32;
	while (n > lo && m > lo && a[n - 1] == b[m - 1]) {
		n -= 1;
		m -= 1;
	}
	const aLength = n - lo;
	const bLength = m - lo;
	if (aLength == 0 && bLength == 0) { return []; }
	const most = Math.min(aLength + bLength, limit);
	const off = most + 1;
	const v: int32[] = [];
	for (let i = 0; i < 2 * most + 3; i++) { v.push(0); }
	const trace: int32[][] = [];
	let found = -1;
	for (let d = 0; d <= most && found < 0; d++) {
		trace.push(v.slice(off - d - 1, off + d + 2));
		for (let k = -d; k <= d && found < 0; k += 2) {
			let x = k == -d || (k != d && v[off + k - 1] < v[off + k + 1]) ? v[off + k + 1] : v[off + k - 1] + 1;
			let y = x - k;
			while (x < aLength && y < bLength && a[lo + x] == b[lo + y]) {
				x += 1;
				y += 1;
			}
			v[off + k] = x;
			if (x >= aLength && y >= bLength) { found = d; }
		}
	}
	if (found < 0) { return null; }
	const gone: boolean[] = [];
	const added: boolean[] = [];
	for (let i = 0; i < aLength; i++) { gone.push(false); }
	for (let j = 0; j < bLength; j++) { added.push(false); }
	let x = aLength;
	let y = bLength;
	for (let d = found; d > 0; d--) {
		const before = trace[d];
		const at = (k: int32): int32 => before[k + d + 1];
		const k = x - y;
		const prevK = k == -d || (k != d && at(k - 1) < at(k + 1)) ? k + 1 : k - 1;
		const prevX = at(prevK);
		const prevY = prevX - prevK;
		while (x > prevX && y > prevY) {
			x -= 1;
			y -= 1;
		}
		if (x == prevX) { added[prevY] = true; } else { gone[prevX] = true; }
		x = prevX;
		y = prevY;
	}
	const out: Hunk[] = [];
	let i = 0;
	let j = 0;
	while (i < aLength || j < bLength) {
		if (i < aLength && j < bLength && !gone[i] && !added[j]) {
			i += 1;
			j += 1;
			continue;
		}
		const h: Hunk = { oldFrom: lo + i, oldTo: lo + i, newFrom: lo + j, newTo: lo + j };
		while (i < aLength && gone[i]) { i += 1; }
		while (j < bLength && added[j]) { j += 1; }
		out.push({ ...h, oldTo: lo + i, newTo: lo + j });
	}
	return out;
}

function starts(tokens: string[]): int32[] {
	const at: int32[] = [0];
	for (const t of tokens) { at.push(at[at.length - 1] + (t.byteLength as int32)); }
	return at;
}

// The replacements that turn `before` into `after`: a diff of lines, then of words inside each
// changed run of at most WORD_DIFF_LINES lines and WORD_DIFF_BYTES bytes on both sides. Past
// DIFF_LIMIT changed tokens a run, or the whole text, is replaced as one.
export function textDiff(before: string, after: string): Replace[] {
	const a = lines(before);
	const b = lines(after);
	const found = hunks(a, b, DIFF_LIMIT);
	if (found === null) { return [{ from: 0, to: before.byteLength as int32, text: after }]; }
	const aAt = starts(a);
	const bAt = starts(b);
	const out: Replace[] = [];
	for (const h of found as Hunk[]) {
		const oldFrom = aAt[h.oldFrom];
		const oldTo = aAt[h.oldTo];
		const newFrom = bAt[h.newFrom];
		const newTo = bAt[h.newTo];
		const wordwise = oldTo > oldFrom && newTo > newFrom
			&& oldTo - oldFrom <= WORD_DIFF_BYTES && newTo - newFrom <= WORD_DIFF_BYTES
			&& h.oldTo - h.oldFrom <= WORD_DIFF_LINES && h.newTo - h.newFrom <= WORD_DIFF_LINES;
		const inner = wordwise ? words(before.byteSlice(oldFrom, oldTo)) : [];
		const innerNew = wordwise ? words(after.byteSlice(newFrom, newTo)) : [];
		const small = wordwise ? hunks(inner, innerNew, DIFF_LIMIT) : null;
		if (small === null) {
			out.push({ from: oldFrom, to: oldTo, text: after.byteSlice(newFrom, newTo) });
			continue;
		}
		const wAt = starts(inner);
		const wNewAt = starts(innerNew);
		for (const w of small as Hunk[]) {
			out.push({
				from: oldFrom + wAt[w.oldFrom],
				to: oldFrom + wAt[w.oldTo],
				text: after.byteSlice(newFrom + wNewAt[w.newFrom], newFrom + wNewAt[w.newTo]),
			});
		}
	}
	return out;
}

function applied(before: string, edits: Replace[]): string {
	let out = "";
	let at = 0;
	for (const e of edits) {
		out += before.byteSlice(at, e.from) + e.text;
		at = e.to;
	}
	return out + before.byteSlice(at, before.byteLength);
}

test "a diff turns the old text into the new and touches only what changed" {
	const before = "function f(a: int32): int32 {\n  let  ab = a+1;\n      ab = ab * 2;\n  return ab;\n}\n";
	const after = "function f(a: int32): int32 {\n  let ab = a + 1;\n  ab = ab * 2;\n  return ab;\n}\n";
	const edits = textDiff(before, after);
	assert applied(before, edits) == after;
	for (const e of edits) { assert e.from >= 30 && e.to <= 66; }
	assert edits.length == 4 && edits[0].from == 35 && edits[0].to == 37 && edits[0].text == " ";
}

test "a diff of equal, emptied, filled and wholly different texts" {
	assert textDiff("same\n", "same\n").length == 0;
	const emptied = textDiff("a\nb\n", "");
	assert emptied.length == 1 && emptied[0].from == 0 && emptied[0].to == 4 && emptied[0].text == "";
	const filled = textDiff("", "x\n");
	assert filled.length == 1 && filled[0].text == "x\n";
	const swapped = textDiff("a\nb\nc\n", "c\nb\na\n");
	assert applied("a\nb\nc\n", swapped) == "c\nb\na\n";
	const tail = textDiff("x\ny", "x\nyz\n");
	assert applied("x\ny", tail) == "x\nyz\n" && tail[0].from >= 2;
}

test "a diff past the limit replaces the whole text" {
	let before = "";
	let after = "";
	for (let i = 0; i < DIFF_LIMIT; i++) {
		before += `a${i}\n`;
		after += `b${i}\n`;
	}
	const edits = textDiff(before, after);
	assert edits.length == 1 && edits[0].from == 0 && edits[0].text == after;
}
