export const ROWS_PER_NOTCH: float64 = 3;

export struct Viewport {
	top: int32;
	rows: int32;
	pending: float64;
}

export function lastTop(this v: Viewport, lineCount: int32): int32 {
	return Math.max(0, lineCount - 1);
}

export function scrolledBy(this v: Viewport, delta: int32, lineCount: int32): Viewport {
	return { ...v, top: Math.min(Math.max(0, v.top + delta), v.lastTop(lineCount)) };
}

export function wheeled(this v: Viewport, notches: float64, lineCount: int32): Viewport {
	const total = v.pending - notches * ROWS_PER_NOTCH;
	const whole = total < 0 ? Math.ceil(total) : Math.floor(total);
	return { ...v.scrolledBy(whole as int32, lineCount), pending: total - whole };
}

export function resized(this v: Viewport, rows: int32, lineCount: int32): Viewport {
	const sized: Viewport = { ...v, rows: Math.max(1, rows) };
	return sized.scrolledBy(0, lineCount);
}

function at(top: int32, rows: int32): Viewport {
	return { top, rows, pending: 0 };
}

test "scrolling stops at the first line" {
	assert at(2, 10).scrolledBy(-5, 100).top == 0;
}

test "scrolling past the end keeps the last line at the top" {
	assert at(90, 10).scrolledBy(50, 100).top == 99;
}

test "an empty document has one top" {
	assert at(0, 10).scrolledBy(3, 0).top == 0;
}

test "a wheel notch down scrolls three rows" {
	assert at(0, 10).wheeled(-1, 100).top == 3;
	assert at(6, 10).wheeled(1, 100).top == 3;
}

test "fractional notches accumulate until they reach a row" {
	const once = at(0, 10).wheeled(-0.2, 100);
	assert once.top == 0;
	const twice = once.wheeled(-0.2, 100);
	assert twice.top == 1;
}

test "shrinking the document while resized pulls the top back" {
	assert at(50, 10).resized(20, 30).top == 29;
}
