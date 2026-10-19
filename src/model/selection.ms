export struct Sel {
	anchor: int32;
	head: int32;
}

export struct Selections {
	ranges: Sel[];
	primary: int32;
}

export function cursorAt(offset: int32): Sel {
	return { anchor: offset, head: offset };
}

export function start(this s: Sel): int32 { return Math.min(s.anchor, s.head); }
export function end(this s: Sel): int32 { return Math.max(s.anchor, s.head); }
export function isEmpty(this s: Sel): boolean { return s.anchor == s.head; }

export function single(offset: int32): Selections {
	return { ranges: [cursorAt(offset)], primary: 0 };
}

function overlaps(a: Sel, b: Sel): boolean {
	return b.start() < a.end() || b.start() == a.start();
}

function union(a: Sel, b: Sel): Sel {
	const from = Math.min(a.start(), b.start());
	const to = Math.max(a.end(), b.end());
	return a.head < a.anchor ? { anchor: to, head: from } : { anchor: from, head: to };
}

export function normalized(s: Selections): Selections {
	if (s.primary < 0 || s.primary >= (s.ranges.length as int32)) {
		throw new Error(`normalized: primary ${s.primary} is outside ${s.ranges.length} ranges`);
	}
	const primaryHead = s.ranges[s.primary].head;
	const sorted = s.ranges.slice(0, s.ranges.length);
	sorted.sort((a: Sel, b: Sel): number => a.start() == b.start() ? a.end() - b.end() : a.start() - b.start());
	const merged: Sel[] = [];
	let primary = 0;
	for (const sel of sorted) {
		const last = merged.length - 1;
		if (last >= 0 && overlaps(merged[last], sel)) {
			merged[last] = union(merged[last], sel);
		} else {
			merged.push(sel);
		}
		if (sel.head == primaryHead) { primary = (merged.length as int32) - 1; }
	}
	return { ranges: merged, primary };
}

test "a selection reads the same either way round" {
	const s: Sel = { anchor: 9, head: 4 };
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
	const n = normalized({ ranges: [{ anchor: 6, head: 2 }, { anchor: 4, head: 9 }], primary: 1 });
	assert n.ranges.length == 1;
	assert n.ranges[0].anchor == 9;
	assert n.ranges[0].head == 2;
	assert n.primary == 0;
}

test "ranges that only touch stay apart" {
	const n = normalized({ ranges: [{ anchor: 0, head: 3 }, { anchor: 3, head: 5 }], primary: 0 });
	assert n.ranges.length == 2;
}
