export struct Sel {
	anchor: int32;
	head: int32;
	goal: int32 | null;
}

export struct Selections {
	ranges: Sel[];
	primary: int32;
}

export function cursorAt(offset: int32): Sel {
	return span(offset, offset);
}

export function span(anchor: int32, head: int32): Sel {
	return { anchor, head, goal: null };
}

export function start(this s: Sel): int32 { return Math.min(s.anchor, s.head); }
export function end(this s: Sel): int32 { return Math.max(s.anchor, s.head); }
export function isEmpty(this s: Sel): boolean { return s.anchor == s.head; }

export function single(offset: int32): Selections {
	return { ranges: [cursorAt(offset)], primary: 0 };
}

export function primaryRange(this s: Selections): Sel { return s.ranges[s.primary]; }

export function sameSelections(this a: Selections, b: Selections): boolean {
	if (a.ranges.length != b.ranges.length) { return false; }
	for (let i = 0; i < a.ranges.length; i++) {
		const x = a.ranges[i];
		const y = b.ranges[i];
		if (x.anchor != y.anchor || x.head != y.head) { return false; }
	}
	return true;
}

function overlaps(this a: Sel, b: Sel): boolean {
	return b.start() < a.end() || b.start() == a.start();
}

function union(this a: Sel, b: Sel): Sel {
	const from = Math.min(a.start(), b.start());
	const to = Math.max(a.end(), b.end());
	return a.head < a.anchor ? span(to, from) : span(from, to);
}

struct Ranked {
	sel: Sel;
	index: int32;
}

export function normalized(this s: Selections): Selections {
	const [merged, _kept] = s.normalizedKeeping(0);
	return merged;
}

export function normalizedKeeping(this s: Selections, kept: int32): [Selections, int32] {
	if (s.primary < 0 || s.primary >= (s.ranges.length as int32)) {
		throw new Error(`normalized: primary ${s.primary} is outside ${s.ranges.length} ranges`);
	}
	if (kept < 0 || kept >= (s.ranges.length as int32)) {
		throw new Error(`normalizedKeeping: range ${kept} is outside ${s.ranges.length} ranges`);
	}
	const primaryHead = s.ranges[s.primary].head;
	const sorted: Ranked[] = [];
	for (let i = 0; i < s.ranges.length; i++) { sorted.push({ sel: s.ranges[i], index: i }); }
	sorted.sort((a: Ranked, b: Ranked) => a.sel.start() == b.sel.start() ?
		a.sel.end() - b.sel.end() : a.sel.start() - b.sel.start());
	const merged: Sel[] = [];
	let primary = 0;
	let keptAt = 0;
	for (const r of sorted) {
		const last = merged.length - 1;
		if (last >= 0 && merged[last].overlaps(r.sel)) {
			merged[last] = merged[last].union(r.sel);
		} else {
			merged.push(r.sel);
		}
		if (r.sel.head == primaryHead) { primary = (merged.length as int32) - 1; }
		if (r.index == kept) { keptAt = (merged.length as int32) - 1; }
	}
	return [{ ranges: merged, primary }, keptAt];
}

test "a selection reads the same either way round" {
	const s = span(9, 4);
	assert s.start() == 4;
	assert s.end() == 9;
	assert !s.isEmpty();
}

test "cursors are sorted and duplicates merge" {
	const n = normalized({ ranges: [cursorAt(8), cursorAt(2), cursorAt(8)], primary: 0 });
	assert n.ranges.length == 2;
	assert n.ranges[0].head == 2;
	assert n.ranges[1].head == 8;
	assert n.primary == 1;
}

test "overlapping ranges merge and keep their direction" {
	const n = normalized({ ranges: [span(6, 2), span(4, 9)], primary: 1 });
	assert n.ranges.length == 1;
	assert n.ranges[0].anchor == 9;
	assert n.ranges[0].head == 2;
	assert n.primary == 0;
}

test "a kept range is followed through sorting and merging" {
	const s: Selections = {
		ranges: [cursorAt(9), span(4, 6), span(5, 8), cursorAt(1)],
		primary: 0,
	};
	const [sorted, first] = s.normalizedKeeping(0);
	assert sorted.ranges.length == 3 && first == 2;
	const [_m, merged] = s.normalizedKeeping(2);
	assert merged == 1;
	const [_o, last] = s.normalizedKeeping(3);
	assert last == 0;
}

test "ranges that only touch stay apart" {
	const n = normalized({ ranges: [span(0, 3), span(3, 5)], primary: 0 });
	assert n.ranges.length == 2;
}
