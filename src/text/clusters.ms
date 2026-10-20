export const TAB_SIZE: int32 = 4;
const TAB: int32 = 9;
const ZWJ: int32 = 0x200D;

// UAX #11 East Asian Width W and F, with emoji blocks taken whole: a few text-presentation symbols count two.
const WIDE: int32[] = [
	0x1100, 0x115F, 0x231A, 0x231B, 0x2329, 0x232A, 0x23E9, 0x23EC, 0x23F0, 0x23F0, 0x23F3, 0x23F3,
	0x25FD, 0x25FE, 0x2614, 0x2615, 0x2648, 0x2653, 0x267F, 0x267F, 0x2693, 0x2693, 0x26A1, 0x26A1,
	0x26AA, 0x26AB, 0x26BD, 0x26BE, 0x26C4, 0x26C5, 0x26CE, 0x26CE, 0x26D4, 0x26D4, 0x26EA, 0x26EA,
	0x26F2, 0x26F3, 0x26F5, 0x26F5, 0x26FA, 0x26FA, 0x26FD, 0x26FD, 0x2705, 0x2705, 0x270A, 0x270B,
	0x2728, 0x2728, 0x274C, 0x274C, 0x274E, 0x274E, 0x2753, 0x2755, 0x2757, 0x2757, 0x2795, 0x2797,
	0x27B0, 0x27B0, 0x27BF, 0x27BF, 0x2B1B, 0x2B1C, 0x2B50, 0x2B50, 0x2B55, 0x2B55, 0x2E80, 0x303E,
	0x3040, 0xA4CF, 0xA960, 0xA97F, 0xAC00, 0xD7A3, 0xF900, 0xFAFF, 0xFE10, 0xFE19, 0xFE30, 0xFE6F,
	0xFF00, 0xFF60, 0xFFE0, 0xFFE6, 0x16FE0, 0x16FE4, 0x17000, 0x18AFF, 0x1B000, 0x1B2FF,
	0x1F004, 0x1F004, 0x1F0CF, 0x1F0CF, 0x1F18E, 0x1F18E, 0x1F191, 0x1F19A, 0x1F200, 0x1F2FF,
	0x1F300, 0x1F64F, 0x1F680, 0x1F6FF, 0x1F7E0, 0x1F7EB, 0x1F900, 0x1F9FF, 0x1FA70, 0x1FAFF,
	0x20000, 0x2FFFD, 0x30000, 0x3FFFD,
];

// Not full UAX #29: Hangul jamo, Indic conjuncts and regional-indicator flags split; widen this when one of them is typed.
const EXTEND: int32[] = [
	0x0300, 0x036F, 0x1AB0, 0x1AFF, 0x1DC0, 0x1DFF, ZWJ, ZWJ, 0x20D0, 0x20FF, 0xFE00, 0xFE0F,
	0xFE20, 0xFE2F, 0x1F3FB, 0x1F3FF, 0xE0020, 0xE007F,
];

function inRanges(ranges: Readonly<Span<int32>>, codePoint: int32): boolean {
	for (let k = 0; k < ranges.length; k += 2) {
		if (codePoint < ranges[k]) { return false; }
		if (codePoint <= ranges[k + 1]) { return true; }
	}
	return false;
}

export function isTrail(byte: int32): boolean { return (byte & 0xC0) == 0x80; }

function stepIn(bytes: Readonly<Span<uint8>>, at: int32): int32 {
	const lead = bytes[at] as int32;
	const length = lead < 0xC0 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4;
	return Math.min(length, (bytes.length as int32) - at);
}

function codePointIn(bytes: Readonly<Span<uint8>>, at: int32): int32 {
	const lead = bytes[at] as int32;
	const length = stepIn(bytes, at);
	if (length == 1) { return lead; }
	let codePoint = lead & match (length) { 2 => 0x1F, 3 => 0x0F, _ => 0x07 };
	for (let k = 1; k < length; k++) {
		codePoint = (codePoint << 6) | ((bytes[at + k] as int32) & 0x3F);
	}
	return codePoint;
}

export function nextClusterIn(bytes: Readonly<Span<uint8>>, from: int32): int32 {
	const total = bytes.length as int32;
	if (from >= total) { return total; }
	let at = from + stepIn(bytes, from);
	while (at < total) {
		const codePoint = codePointIn(bytes, at);
		if (!inRanges(EXTEND, codePoint)) { break; }
		at += stepIn(bytes, at);
		if (codePoint == ZWJ && at < total) { at += stepIn(bytes, at); }
	}
	return at;
}

function startsClusterIn(bytes: Readonly<Span<uint8>>, at: int32): boolean {
	if (isTrail(bytes[at] as int32) || inRanges(EXTEND, codePointIn(bytes, at))) { return false; }
	if (at == 0) { return true; }
	let prev = at - 1;
	while (prev > 0 && isTrail(bytes[prev] as int32)) { prev -= 1; }
	return codePointIn(bytes, prev) != ZWJ;
}

export function prevClusterIn(bytes: Readonly<Span<uint8>>, to: int32): int32 {
	if (to <= 0) { return 0; }
	let from = to - 1;
	while (from > 0 && !startsClusterIn(bytes, from)) { from -= 1; }
	let last = from;
	let at = from;
	while (at < to) {
		last = at;
		at = nextClusterIn(bytes, at);
	}
	return last;
}

export function clusterCellsIn(bytes: Readonly<Span<uint8>>, at: int32, cell: int32): int32 {
	const lead = bytes[at] as int32;
	if (lead == TAB) { return TAB_SIZE - cell % TAB_SIZE; }
	if (lead < 0x80) { return 1; }
	return inRanges(WIDE, codePointIn(bytes, at)) ? 2 : 1;
}

export function cellsIn(bytes: Readonly<Span<uint8>>, from: int32, to: int32, cell: int32): int32 {
	let at = from;
	let column = cell;
	while (at < to) {
		column += clusterCellsIn(bytes, at, column);
		at = nextClusterIn(bytes, at);
	}
	return column - cell;
}

export function offsetAtCellIn(
	bytes: Readonly<Span<uint8>>,
	from: int32,
	to: int32,
	cell: int32,
	target: int32,
): int32 {
	const goal = cell + target;
	let at = from;
	let column = cell;
	while (at < to) {
		const width = clusterCellsIn(bytes, at, column);
		if (column + width > goal) {
			return (goal - column) * 2 <= width ? at : nextClusterIn(bytes, at);
		}
		column += width;
		at = nextClusterIn(bytes, at);
	}
	return at;
}

test "a cluster holds a multi-byte code point, its combining marks and a ZWJ sequence" {
	const b = "a😀é👩‍💻👍🏽x".asBytes();
	assert nextClusterIn(b, 0) == 1;
	assert nextClusterIn(b, 1) == 5;
	assert nextClusterIn(b, 5) == 8;
	assert nextClusterIn(b, 8) == 19;
	assert nextClusterIn(b, 19) == 27;
	assert nextClusterIn(b, 27) == 28;
	assert prevClusterIn(b, 28) == 27;
	assert prevClusterIn(b, 27) == 19;
	assert prevClusterIn(b, 19) == 8;
	assert prevClusterIn(b, 8) == 5;
	assert prevClusterIn(b, 5) == 1;
}

test "cells count a wide cluster two and a tab to the next stop" {
	const b = "a😀\tb中".asBytes();
	assert cellsIn(b, 0, 5, 0) == 3;
	assert cellsIn(b, 0, 6, 0) == 4;
	assert cellsIn(b, 5, 6, 1) == 3;
	assert cellsIn(b, 0, 10, 0) == 7;
	assert offsetAtCellIn(b, 0, 10, 0, 2) == 1;
	assert offsetAtCellIn(b, 0, 10, 0, 6) == 7;
	assert offsetAtCellIn(b, 0, 10, 0, 99) == 10;
}

test "a range table holds the first and the last code point of each range" {
	const ranges = [10, 20, 30, 30];
	assert !inRanges(ranges, 9);
	assert inRanges(ranges, 10);
	assert inRanges(ranges, 20);
	assert !inRanges(ranges, 21);
	assert inRanges(ranges, 30);
	assert !inRanges(ranges, 31);
}

test "a variation selector and a tag stay in the cluster before them" {
	const b = "\u2764\uFE0Fx\u{1F3F4}\u{E0067}\u{E007F}y".asBytes();
	assert nextClusterIn(b, 0) == 6;
	assert nextClusterIn(b, 6) == 7;
	assert nextClusterIn(b, 7) == 19;
	assert prevClusterIn(b, 19) == 7;
	assert prevClusterIn(b, 6) == 0;
}
