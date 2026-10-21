import { TextSpan } from "../../../../../../neon/src/render/hostTypes";
import { Style } from "../../../../../../neon/src/render/style";
import { Document } from "../../../../model/document";
import { Sel, Selections, end, isEmpty, primaryRange, span, start } from "../../../../model/selection";
import { Inlay } from "../../../../model/inlays";
import { Viewport } from "../../../../view/viewport";
import { Mark, Piece, VisualRow, cellIn, holds, rowCells, rowPieces, rowsOf } from "../../../../view/wrap";
import { Diagnostic, Severity } from "../../../../model/diagnostics";
import { Syntax } from "../../../../syntax/syntax";
import { Occurrence } from "../../../../model/occurrences";
import {
	CARET,
	BRACKET,
	CURRENT_LINE,
	CURRENT_NUMBER,
	MATCH,
	MUTED,
	READ_HIGHLIGHT,
	WRITE_HIGHLIGHT,
	FADED_ALPHA,
	SELECTION,
	colorOf,
	severityColor,
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

export function framed(doc: Document, view: Viewport, wrapWidth: int32, lineInlays: (line: int32) => Inlay[]): VisualRow[] {
	const out: VisualRow[] = [];
	const full = (): boolean => (out.length as int32) >= view.rows;
	for (let line = view.line; line < doc.lineCount() && !full(); line++) {
		const lineRows = rowsOf(doc, line, wrapWidth, wrapWidth > 0 ? lineInlays(line) : []);
		const first = line == view.line ? view.sub : 0;
		for (let k = first; k < (lineRows.length as int32) && !full(); k++) {
			out.push(lineRows[k]);
		}
	}
	return out;
}

function markOf(d: Diagnostic): Mark {
	const drawn = !d.unnecessary || d.severity <= Severity.Warning;
	return { from: d.from, to: d.to, faded: d.unnecessary, underline: drawn ? d.severity : null };
}

function styleOf(p: Piece): Style {
	if (p.hint) { return { color: MUTED }; }
	const color = colorOf(p.tone) + (p.faded ? FADED_ALPHA : "");
	if (p.underline === null) { return { color }; }
	return {
		color,
		textDecorationLine: "underline",
		textDecorationStyle: "wavy",
		textDecorationColor: severityColor(p.underline as Severity),
	};
}

export function painted(
	doc: Document,
	selections: Selections,
	marks: Sel[],
	brackets: Sel[],
	occurrences: Occurrence[],
	frame: VisualRow[],
	view: Viewport,
	syntax: Syntax | null,
	diagnostics: Diagnostic[],
	grid: Grid,
	inlays: Inlay[],
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
	const decor = diagnostics.map((d: Diagnostic): Mark => markOf(d));
	const rows: Row[] = [];
	for (const r of frame) {
		const number = r.cell == 0 ? `${r.line + 1}` : "";
		const spans: TextSpan[] = [{
			text: number.padStart(digits, " ") + "".padStart(GUTTER_GAP, " "),
			style: { color: r.line == current ? CURRENT_NUMBER : MUTED },
		}];
		for (const p of rowPieces(doc, r, view.left, view.cols, tones, top, decor, inlays)) {
			spans.push({ text: p.text, style: styleOf(p) });
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
	const shade = (s: Sel, color: string, out: Box[]): void => {
		for (let i = 0; i < (frame.length as int32); i++) {
			const r = frame[i];
			const lo = Math.max(s.start(), r.from);
			const hi = Math.min(s.end(), r.to);
			const newline = r.last && s.start() <= r.to && s.end() > r.to;
			if (lo < hi || (newline && lo <= hi)) {
				const from = cellIn(doc, r, lo, inlays);
				const to = newline ? rowCells(doc, r, inlays) + 1 : cellIn(doc, r, hi, inlays);
				const left = Math.max(from, view.left);
				const right = Math.min(to, view.left + view.cols);
				if (left < right) {
					out.push(at(i, left - view.left, (right - left) * cellWidth, color));
				}
			}
		}
	};
	const bands: Box[] = [];
	const found: Box[] = [];
	const shades: Box[] = [];
	const carets: Box[] = [];
	let primary: Box | null = null;
	for (const o of occurrences) { shade(span(o.from, o.to), o.write ? WRITE_HIGHLIGHT : READ_HIGHLIGHT, found); }
	for (const m of marks) { shade(m, MATCH, found); }
	for (const b of brackets) { shade(b, BRACKET, found); }
	for (const s of selections.ranges) {
		if (s.end() < top || s.start() > bottom + 1) { continue; }
		for (let i = 0; i < (frame.length as int32); i++) {
			const r = frame[i];
			if (r.holds(s.head)) {
				const cell = cellIn(doc, r, s.head, inlays) - view.left;
				const caret = at(i, Math.max(0, cell), CARET_WIDTH, CARET);
				if (cell >= 0 && cell <= view.cols) { carets.push(caret); }
				if (s.isEmpty()) { bands.push(at(i, 0, view.cols * cellWidth, CURRENT_LINE)); }
				if (s.head == head) { primary = caret; }
			}
		}
		shade(s, SELECTION, shades);
	}
	return { rows, shades: bands.concat(found).concat(shades), carets, primary };
}
