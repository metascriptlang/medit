import { TextSpan } from "../../../../../../neon/src/render/hostTypes";
import { Document } from "../../../../model/document";
import { Selections, end, isEmpty, primaryRange, start } from "../../../../model/selection";
import { cellsBetween } from "../../../../model/motion";
import { Viewport } from "../../../../view/viewport";
import { VisualRow, cellIn, holds, rowPieces, rowsOf } from "../../../../view/wrap";
import { Syntax } from "../../../../syntax/syntax";
import {
	CARET,
	CURRENT_LINE,
	CURRENT_NUMBER,
	MUTED,
	SELECTION,
	colorOf,
} from "../../../theme";
import { Box } from "../../ui/overlay";
import { Row } from "../../content/lineRow";

const CARET_WIDTH: float64 = 2;
const MIN_DIGITS: int32 = 3;
const GUTTER_GAP: int32 = 2;

export struct Grid {
	cellWidth: float64;
	rowHeight: float64;
}

export struct Painted {
	rows: Row[];
	shades: Box[];
	carets: Box[];
	primary: Box | null;
}

export function gutterWidth(lineCount: int32): int32 {
	return Math.max(MIN_DIGITS, `${lineCount}`.length as int32) + GUTTER_GAP;
}

export function framed(doc: Document, view: Viewport, wrapWidth: int32): VisualRow[] {
	const out: VisualRow[] = [];
	const full = (): boolean => (out.length as int32) >= view.rows;
	for (let line = view.line; line < doc.lineCount() && !full(); line++) {
		const lineRows = rowsOf(doc, line, wrapWidth);
		const first = line == view.line ? view.sub : 0;
		for (let k = first; k < (lineRows.length as int32) && !full(); k++) {
			out.push(lineRows[k]);
		}
	}
	return out;
}

export function painted(
	doc: Document,
	selections: Selections,
	frame: VisualRow[],
	view: Viewport,
	syntax: Syntax | null,
	grid: Grid,
): Painted {
	const { cellWidth, rowHeight } = grid;
	const gutter = gutterWidth(doc.lineCount());
	const textX = gutter * cellWidth;
	const digits = gutter - GUTTER_GAP;
	const head = selections.primaryRange().head;
	const current = doc.lineOf(head);
	const top = frame.length > 0 ? frame[0].from : 0;
	const bottom = frame.length > 0 ? frame[frame.length - 1].to : 0;
	const tones = syntax === null ? [] : syntax.tonesIn(doc, top, bottom);
	const rows: Row[] = [];
	for (const r of frame) {
		const number = r.cell == 0 ? `${r.line + 1}` : "";
		const spans: TextSpan[] = [{
			text: number.padStart(digits, " ") + "".padStart(GUTTER_GAP, " "),
			style: { color: r.line == current ? CURRENT_NUMBER : MUTED },
		}];
		for (const p of rowPieces(doc, r, view.left, view.cols, tones, top)) {
			spans.push({ text: p.text, style: { color: colorOf(p.tone) } });
		}
		rows.push({ spans });
	}
	const at = (row: int32, cell: int32, width: float64, color: string): Box => ({
		x: textX + cell * cellWidth,
		y: row * rowHeight,
		width,
		height: rowHeight,
		color,
	});
	const bands: Box[] = [];
	const shades: Box[] = [];
	const carets: Box[] = [];
	let primary: Box | null = null;
	for (const s of selections.ranges) {
		if (s.end() < top || s.start() > bottom + 1) { continue; }
		for (let i = 0; i < (frame.length as int32); i++) {
			const r = frame[i];
			if (r.holds(s.head)) {
				const cell = cellIn(doc, r, s.head) - view.left;
				const caret = at(i, Math.max(0, cell), CARET_WIDTH, CARET);
				if (cell >= 0 && cell <= view.cols) { carets.push(caret); }
				if (s.isEmpty()) { bands.push(at(i, 0, view.cols * cellWidth, CURRENT_LINE)); }
				if (s.head == head) { primary = caret; }
			}
			const lo = Math.max(s.start(), r.from);
			const hi = Math.min(s.end(), r.to);
			const newline = r.last && s.start() <= r.to && s.end() > r.to;
			if (lo < hi || (newline && lo <= hi)) {
				const from = cellIn(doc, r, lo);
				const to = from + doc.cellsBetween(lo, hi, r.cell + from) + (newline ? 1 : 0);
				const left = Math.max(from, view.left);
				const right = Math.min(to, view.left + view.cols);
				if (left < right) {
					shades.push(at(i, left - view.left, (right - left) * cellWidth, SELECTION));
				}
			}
		}
	}
	return { rows, shades: bands.concat(shades), carets, primary };
}
