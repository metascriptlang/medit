export const ROWS_PER_NOTCH: float64 = 3;
export const COLS_PER_NOTCH: float64 = 6;
const DRAG_SCROLL_MAX_ROWS: float64 = 3;
const DRAG_SCROLL_EASE: float64 = 1.2;
const DRAG_SCROLL_PX_PER_ROW: float64 = 100;

export type RowCount = (line: int32) => int32;
export type LineSpan = (line: int32) => [int32, int32];

function whole(line: int32): [int32, int32] { return [line, line]; }

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
	spanOf: LineSpan = whole,
): Viewport {
	const last = Math.max(0, lineCount - 1);
	let line = spanOf(Math.min(v.line, last))[0];
	let sub = v.sub + delta;
	while (sub < 0 && line > 0) {
		line = spanOf(line - 1)[0];
		sub += rowsIn(line);
	}
	let here = rowsIn(line);
	while (sub >= here) {
		const below = spanOf(line)[1] + 1;
		if (below > last) { break; }
		sub -= here;
		line = below;
		here = rowsIn(line);
	}
	return { ...v, line, sub: Math.max(0, Math.min(sub, here - 1)) };
}

export function nudged(
	this v: Viewport,
	rows: float64,
	lineCount: int32,
	rowsIn: RowCount,
	spanOf: LineSpan = whole,
): Viewport {
	const total = v.pending + rows;
	const steps = total as int32;
	return { ...v.scrolledBy(steps, lineCount, rowsIn, spanOf), pending: total - steps };
}

export function dragScrollRows(y: float64, height: float64, rowHeight: float64): float64 {
	const margin = Math.min(rowHeight, height / 3);
	const beyond = y < margin ? y - margin : y > height - margin ? y - (height - margin) : 0;
	const rows = Math.min(
		Math.pow(Math.abs(beyond), DRAG_SCROLL_EASE) / DRAG_SCROLL_PX_PER_ROW,
		DRAG_SCROLL_MAX_ROWS,
	);
	return beyond < 0 ? -rows : rows;
}

export function wheeled(
	this v: Viewport,
	notches: float64,
	lineCount: int32,
	rowsIn: RowCount,
	spanOf: LineSpan = whole,
): Viewport {
	return v.nudged(-notches * ROWS_PER_NOTCH, lineCount, rowsIn, spanOf);
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
	spanOf: LineSpan = whole,
): Viewport {
	const sized: Viewport = { ...v, rows: Math.max(1, rows), cols: Math.max(1, cols) };
	return sized.scrolledBy(0, lineCount, rowsIn, spanOf);
}

export function revealed(
	this v: Viewport,
	line: int32,
	sub: int32,
	lineCount: int32,
	rowsIn: RowCount,
	spanOf: LineSpan = whole,
): Viewport {
	const target: Viewport = { ...v, line, sub };
	if (line < v.line || (line == v.line && sub < v.sub)) { return target; }
	let seen = -v.sub;
	for (let above = v.line; above < line && seen < v.rows; above = spanOf(above)[1] + 1) { seen += rowsIn(above); }
	if (seen + sub < v.rows) { return v; }
	return target.scrolledBy(1 - v.rows, lineCount, rowsIn, spanOf);
}

export function centered(
	this v: Viewport,
	line: int32,
	lineCount: int32,
	rowsIn: RowCount,
	spanOf: LineSpan = whole,
): Viewport {
	const target: Viewport = { ...v, line, sub: 0, pending: 0 };
	return target.scrolledBy(-(v.rows / 2), lineCount, rowsIn, spanOf);
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

test "a drag scrolls only past a one-row margin, faster the farther it goes, at most three rows" {
	assert dragScrollRows(300, 600, 20) == 0;
	assert dragScrollRows(575, 600, 20) == 0;
	const hundredPast = dragScrollRows(680, 600, 20);
	assert hundredPast > 2.5 && hundredPast < 2.52;
	assert dragScrollRows(10, 600, 20) < 0;
	assert dragScrollRows(-2000, 600, 20) == -3;
	assert dragScrollRows(700, 600, 20) > dragScrollRows(650, 600, 20);
}

test "a centered line sits in the middle row, or as low as the top allows" {
	const one = (line: int32): int32 => 1;
	const v: Viewport = { line: 0, sub: 0, left: 0, rows: 10, cols: 80, pending: 0 };
	assert v.centered(50, 100, one).line == 45;
	assert v.centered(2, 100, one).line == 0;
	assert v.centered(99, 100, one).line == 94;
}

test "scrolling and revealing step over the lines a fold joins into one" {
	const joined = (line: int32): [int32, int32] => line >= 3 && line <= 7 ? [3, 7] : [line, line];
	assert at(2, 4).scrolledBy(1, 100, one, joined).line == 3;
	assert at(3, 4).scrolledBy(1, 100, one, joined).line == 8;
	assert at(8, 4).scrolledBy(-1, 100, one, joined).line == 3;
	assert at(5, 4).scrolledBy(0, 100, one, joined).line == 3;
	assert at(0, 5).revealed(8, 0, 100, one, joined).line == 0;
	assert at(0, 4).revealed(8, 0, 100, one, joined).line == 1;
	assert at(0, 4).revealed(9, 0, 100, one, joined).line == 2;
	assert at(0, 4).scrolledBy(50, 8, one, joined).line == 3;
}
