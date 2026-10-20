export const ROWS_PER_NOTCH: float64 = 3;
export const COLS_PER_NOTCH: float64 = 6;

export type RowCount = (line: int32) => int32;

export struct Viewport {
	line: int32;
	sub: int32;
	left: int32;
	rows: int32;
	cols: int32;
	pending: float64;
}

export function scrolledBy(
	this v: Viewport,
	delta: int32,
	lineCount: int32,
	rowsIn: RowCount,
): Viewport {
	const last = Math.max(0, lineCount - 1);
	let line = Math.min(v.line, last);
	let sub = v.sub + delta;
	while (sub < 0 && line > 0) {
		line -= 1;
		sub += rowsIn(line);
	}
	let here = rowsIn(line);
	while (sub >= here && line < last) {
		sub -= here;
		line += 1;
		here = rowsIn(line);
	}
	return { ...v, line, sub: Math.max(0, Math.min(sub, here - 1)) };
}

export function wheeled(
	this v: Viewport,
	notches: float64,
	lineCount: int32,
	rowsIn: RowCount,
): Viewport {
	const total = v.pending - notches * ROWS_PER_NOTCH;
	const whole = total as int32;
	return { ...v.scrolledBy(whole, lineCount, rowsIn), pending: total - whole };
}

export function slid(this v: Viewport, notches: float64, widest: int32): Viewport {
	const left = v.left + (Math.round(notches * COLS_PER_NOTCH) as int32);
	return { ...v, left: Math.max(0, Math.min(left, widest - v.cols + 1)) };
}

export function resized(
	this v: Viewport,
	rows: int32,
	cols: int32,
	lineCount: int32,
	rowsIn: RowCount,
): Viewport {
	const sized: Viewport = { ...v, rows: Math.max(1, rows), cols: Math.max(1, cols) };
	return sized.scrolledBy(0, lineCount, rowsIn);
}

export function revealed(
	this v: Viewport,
	line: int32,
	sub: int32,
	lineCount: int32,
	rowsIn: RowCount,
): Viewport {
	const target: Viewport = { ...v, line, sub };
	if (line < v.line || (line == v.line && sub < v.sub)) { return target; }
	let seen = -v.sub;
	for (let above = v.line; above < line && seen < v.rows; above++) { seen += rowsIn(above); }
	if (seen + sub < v.rows) { return v; }
	return target.scrolledBy(1 - v.rows, lineCount, rowsIn);
}

export function revealedCell(this v: Viewport, cell: int32): Viewport {
	if (cell < v.left) { return { ...v, left: cell }; }
	if (cell >= v.left + v.cols) { return { ...v, left: cell - v.cols + 1 }; }
	return v;
}

function at(line: int32, rows: int32): Viewport {
	return { line, sub: 0, left: 0, rows, cols: 80, pending: 0 };
}

function one(line: int32): int32 { return 1; }

function three(line: int32): int32 { return 3; }

test "scrolling stops at the first line" {
	assert at(2, 10).scrolledBy(-5, 100, one).line == 0;
}

test "scrolling past the end keeps the last row at the top" {
	assert at(90, 10).scrolledBy(50, 100, one).line == 99;
	const wrapped = at(90, 10).scrolledBy(50, 100, three);
	assert wrapped.line == 99;
	assert wrapped.sub == 2;
}

test "an empty document has one top" {
	assert at(0, 10).scrolledBy(3, 0, one).line == 0;
}

test "scrolling steps through the rows of wrapped lines" {
	const v = at(5, 10).scrolledBy(4, 100, three);
	assert v.line == 6;
	assert v.sub == 1;
	const back = v.scrolledBy(-2, 100, three);
	assert back.line == 5;
	assert back.sub == 2;
}

test "a wheel notch down scrolls three rows" {
	assert at(0, 10).wheeled(-1, 100, one).line == 3;
	assert at(6, 10).wheeled(1, 100, one).line == 3;
}

test "fractional notches accumulate until they reach a row" {
	const once = at(0, 10).wheeled(-0.2, 100, one);
	assert once.line == 0;
	const twice = once.wheeled(-0.2, 100, one);
	assert twice.line == 1;
	const up = at(5, 10).wheeled(0.2, 100, one);
	assert up.line == 5;
	assert up.wheeled(0.2, 100, one).line == 4;
}

test "shrinking the document while resized pulls the top back" {
	assert at(50, 10).resized(20, 80, 30, one).line == 29;
}

test "revealing a row scrolls only as far as it takes" {
	assert at(10, 5).revealed(12, 0, 100, one).line == 10;
	assert at(10, 5).revealed(3, 0, 100, one).line == 3;
	assert at(10, 5).revealed(20, 0, 100, one).line == 16;
	const wrapped = at(10, 5).revealed(11, 2, 100, three);
	assert wrapped.line == 10;
	assert wrapped.sub == 1;
}

test "a cell is revealed by sliding the left edge" {
	const v: Viewport = { ...at(0, 5), cols: 10 };
	assert v.revealedCell(9).left == 0;
	assert v.revealedCell(10).left == 1;
	assert v.revealedCell(25).revealedCell(3).left == 3;
	assert v.slid(-1, 100).left == 0;
	assert v.slid(2, 100).left == 12;
	assert v.slid(50, 30).left == 21;
}
