import { Bias, Document } from "../model/document";
import { cellsBetween, offsetAtCell, prevCluster } from "../model/motion";
import { cellsIn, clusterCellsIn, nextClusterIn, offsetAtCellIn } from "../text/clusters";
import { Tone } from "./tone";
import { Severity } from "../model/diagnostics";
import { Inlay } from "../model/inlays";
import { Fold, PLACEHOLDER, foldsWithin, shownEnd, shownLine } from "../model/folds";

const TAB: int32 = 9;
const SPACE: int32 = 32;
const DELETE: int32 = 0x7F;

export struct Piece {
	text: string;
	tone: Tone;
	faded: boolean;
	underline: Severity | null;
	hint: boolean;
}

export struct Mark {
	from: int32;
	to: int32;
	faded: boolean;
	underline: Severity | null;
}

export struct VisualRow {
	line: int32;
	from: int32;
	to: int32;
	cell: int32;
	last: boolean;
}

export struct ShownCell {
	text: int32;
	hintAt: int32;
	fold: boolean;
}

struct Stretch {
	from: int32;
	to: int32;
	at: int32;
}

function stretches(from: int32, to: int32, hidden: Fold[]): Stretch[] {
	const out: Stretch[] = [];
	let here = from;
	let at = 0;
	for (const f of hidden) {
		const end = Math.max(here, Math.min(f.from, to));
		out.push({ from: here, to: end, at });
		at += end - here;
		here = Math.max(here, Math.min(f.to, to));
	}
	out.push({ from: here, to: Math.max(here, to), at });
	return out;
}

function seenText(doc: Document, ss: Stretch[]): string {
	let text = "";
	for (const s of ss) { text += doc.slice(s.from, s.to); }
	return text;
}

function docAt(ss: Stretch[], local: int32, right: boolean): int32 {
	const last = (ss.length as int32) - 1;
	for (let k = 0; k < last; k++) {
		const s = ss[k];
		const end = s.at + s.to - s.from;
		if (local < end || (local == end && !right)) { return s.from + local - s.at; }
	}
	return ss[last].from + local - ss[last].at;
}

function seenCells(doc: Document, from: int32, to: int32, cell: int32, hidden: Fold[]): int32 {
	if (hidden.length == 0) { return cellsBetween(doc, from, to, cell); }
	const bytes = seenText(doc, stretches(from, to, hidden)).asBytes();
	return cellsIn(bytes, 0, bytes.length as int32, cell);
}

function foldedBetween(folds: Fold[], from: int32, to: int32): int32 {
	let bytes = 0;
	for (const f of foldsWithin(folds, from, to)) { bytes += Math.min(f.to, to) - Math.max(f.from, from); }
	return bytes;
}

function placed(inlays: Inlay[], hidden: Fold[]): Inlay[] {
	if (hidden.length == 0) { return inlays; }
	const out: Inlay[] = [];
	const count = inlays.length as int32;
	let k = 0;
	for (const f of hidden) {
		while (k < count && inlays[k].at <= f.from) { out.push(inlays[k]); k++; }
		out.push({ at: f.from, text: PLACEHOLDER, bias: Bias.Right });
		while (k < count && inlays[k].at < f.to) { k++; }
	}
	while (k < count) { out.push(inlays[k]); k++; }
	return out;
}

function isPlaceholder(i: Inlay, hidden: Fold[]): boolean {
	if (i.text != PLACEHOLDER) { return false; }
	for (const f of hidden) {
		if (f.from == i.at) { return true; }
	}
	return false;
}

function inlayCells(i: Inlay): int32 {
	const bytes = i.text.asBytes();
	return cellsIn(bytes, 0, bytes.length as int32, 0);
}

function firstInlay(inlays: Inlay[], from: int32): int32 {
	let k = 0;
	while (k < (inlays.length as int32) && inlays[k].at < from) { k++; }
	return k;
}

function shows(this r: VisualRow, i: Inlay): boolean {
	return i.at >= r.from && (i.at < r.to || (r.last && i.at == r.to));
}

export function rowsOf(
	doc: Document,
	asked: int32,
	width: int32,
	lineInlays: Inlay[] = [],
	folds: Fold[] = [],
): Vec<VisualRow> {
	const line = folds.length == 0 ? asked : doc.shownLine(folds, asked);
	const start = doc.lineStart(line);
	const stop = folds.length == 0 ? doc.lineEnd(line) : doc.shownEnd(folds, line);
	let rows: Vec<VisualRow> = [];
	if (width <= 0) {
		rows.push({ line, from: start, to: stop, cell: 0, last: true });
		return rows;
	}
	const hidden = foldsWithin(folds, start, stop);
	const plain = hidden.length == 0;
	const ss = plain ? [] : stretches(start, stop, hidden);
	const inlays = placed(lineInlays, hidden);
	const text = plain ? doc.line(line) : seenText(doc, ss);
	const bytes = text.asBytes();
	const end = bytes.length as int32;
	const count = inlays.length as int32;
	let k = firstInlay(inlays, start);
	let from = 0;
	let rowCell = 0;
	let rowShown = 0;
	let at = 0;
	let cell = 0;
	let shown = 0;
	let breakAt = -1;
	let breakCell = 0;
	let breakShown = 0;
	while (at < end) {
		let hinted = 0;
		let past = k;
		while (past < count && inlays[past].at <= (plain ? start + at : docAt(ss, at, true))) {
			hinted += inlayCells(inlays[past]);
			past++;
		}
		const cells = clusterCellsIn(bytes, at, cell);
		if (shown + hinted + cells - rowShown > width && at > from) {
			const soft = breakAt > from;
			const cut = soft ? breakAt : at;
			rows.push({
				line,
				from: plain ? start + from : docAt(ss, from, false),
				to: plain ? start + cut : docAt(ss, cut, false),
				cell: rowCell,
				last: false,
			});
			from = cut;
			rowCell = soft ? breakCell : cell;
			rowShown = soft ? breakShown : shown;
			breakAt = -1;
			continue;
		}
		k = past;
		const lead = bytes[at] as int32;
		cell += cells;
		shown += hinted + cells;
		at = nextClusterIn(bytes, at);
		if (lead == SPACE || lead == TAB) {
			breakAt = at;
			breakCell = cell;
			breakShown = shown;
		}
	}
	rows.push({ line, from: plain ? start + from : docAt(ss, from, false), to: stop, cell: rowCell, last: true });
	return rows;
}

export function rowIndexOf(rows: Readonly<Span<VisualRow>>, offset: int32): int32 {
	for (let k = 0; k < rows.length; k++) {
		if (rows[k].last || offset < rows[k].to) { return k; }
	}
	return (rows.length as int32) - 1;
}

export function holds(this r: VisualRow, offset: int32): boolean {
	return offset >= r.from && (offset < r.to || (r.last && offset == r.to));
}

export function cellIn(doc: Document, r: VisualRow, offset: int32, lineInlays: Inlay[] = [], folds: Fold[] = []): int32 {
	const hidden = foldsWithin(folds, r.from, r.to);
	const inlays = placed(lineInlays, hidden);
	let hinted = 0;
	for (let k = firstInlay(inlays, r.from); k < (inlays.length as int32) && inlays[k].at <= offset; k++) {
		const i = inlays[k];
		if (r.shows(i) && (i.at < offset || i.bias == Bias.Left)) { hinted += inlayCells(i); }
	}
	return seenCells(doc, r.from, offset, r.cell, hidden) + hinted;
}

export function rowCells(doc: Document, r: VisualRow, lineInlays: Inlay[] = [], folds: Fold[] = []): int32 {
	const hidden = foldsWithin(folds, r.from, r.to);
	const inlays = placed(lineInlays, hidden);
	let hinted = 0;
	for (let k = firstInlay(inlays, r.from); k < (inlays.length as int32) && inlays[k].at <= r.to; k++) {
		if (r.shows(inlays[k])) { hinted += inlayCells(inlays[k]); }
	}
	return seenCells(doc, r.from, r.to, r.cell, hidden) + hinted;
}

export function shownCellIn(
	doc: Document,
	r: VisualRow,
	cell: int32,
	lineInlays: Inlay[] = [],
	folds: Fold[] = [],
): ShownCell {
	const hidden = foldsWithin(folds, r.from, r.to);
	const inlays = placed(lineInlays, hidden);
	let hinted = 0;
	for (let k = firstInlay(inlays, r.from); k < (inlays.length as int32) && inlays[k].at <= r.to; k++) {
		const i = inlays[k];
		if (!r.shows(i)) { continue; }
		const left = seenCells(doc, r.from, i.at, r.cell, hidden) + hinted;
		const width = inlayCells(i);
		if (cell < left) { break; }
		if (cell < left + width) { return { text: cell - hinted, hintAt: i.at, fold: isPlaceholder(i, hidden) }; }
		hinted += width;
	}
	return { text: cell - hinted, hintAt: -1, fold: false };
}

export function textOffsetIn(doc: Document, r: VisualRow, cell: int32, folds: Fold[] = []): int32 {
	const hidden = foldsWithin(folds, r.from, r.to);
	if (hidden.length == 0) { return offsetAtCell(doc, r.from, r.to, r.cell, cell); }
	const ss = stretches(r.from, r.to, hidden);
	const bytes = seenText(doc, ss).asBytes();
	return docAt(ss, offsetAtCellIn(bytes, 0, bytes.length as int32, r.cell, cell), true);
}

export function offsetIn(doc: Document, r: VisualRow, cell: int32, inlays: Inlay[] = [], folds: Fold[] = []): int32 {
	const shown = shownCellIn(doc, r, cell, inlays, folds);
	if (shown.hintAt >= 0) { return shown.hintAt; }
	const at = textOffsetIn(doc, r, shown.text, folds);
	return !r.last && at == r.to ? prevCluster(doc, r.to) : at;
}

function pushSpaces(this out: uint8[], count: int32): void {
	for (let k = 0; k < count; k++) { out.push(SPACE as uint8); }
}

function pushControlPicture(this out: uint8[], lead: int32): void {
	out.push(0xE2 as uint8);
	out.push(0x90 as uint8);
	out.push((lead == DELETE ? 0xA1 : 0x80 + lead) as uint8);
}

function toneAt(tones: Readonly<Span<Tone>>, index: int32): Tone {
	return index >= 0 && index < (tones.length as int32) ? tones[index] : Tone.Plain;
}

function markAt(marks: Mark[], offset: int32): Mark {
	let faded = false;
	let underline: Severity | null = null;
	for (const m of marks) {
		if (m.from <= offset && offset < m.to) {
			faded = faded || m.faded;
			if (m.underline !== null && (underline === null || (m.underline as Severity) < (underline as Severity))) {
				underline = m.underline;
			}
		}
	}
	return { from: offset, to: offset + 1, faded, underline };
}

export function rowPieces(
	doc: Document,
	r: VisualRow,
	left: int32,
	cols: int32,
	tones: Readonly<Span<Tone>>,
	base: int32,
	marks: Mark[],
	lineInlays: Inlay[] = [],
	folds: Fold[] = [],
): Vec<Piece> {
	let pieces: Vec<Piece> = [];
	let out: uint8[] = [];
	let tone = Tone.Plain;
	let faded = false;
	let underline: Severity | null = null;
	const hidden = foldsWithin(folds, r.from, r.to);
	const plain = hidden.length == 0;
	const ss = plain ? [] : stretches(r.from, r.to, hidden);
	const inlays = placed(lineInlays, hidden);
	const toneBase = r.from - base - (folds.length == 0 ? 0 : foldedBetween(folds, base, r.from));
	const text = plain ? doc.slice(r.from, r.to) : seenText(doc, ss);
	const bytes = text.asBytes();
	const end = bytes.length as int32;
	const first = r.cell + left;
	const limit = first + cols;
	const count = inlays.length as int32;
	let h = firstInlay(inlays, r.from);
	let at = 0;
	let cell = r.cell;
	let shift = 0;
	while (at <= end && cell + shift < limit) {
		while (h < count && inlays[h].at <= (plain ? r.from + at : docAt(ss, at, true)) && (at < end || r.last)) {
			const width = inlayCells(inlays[h]);
			const x = cell + shift;
			if (x + width > first && x < limit) {
				if (out.length > 0) {
					pieces.push({ text: out.asString(), tone, faded, underline, hint: false });
					out = [];
				}
				const shown = inlayText(inlays[h].text, Math.max(0, first - x), Math.min(x + width, limit) - Math.max(x, first));
				pieces.push({ text: shown, tone: Tone.Plain, faded: false, underline: null, hint: true });
			}
			shift += width;
			h++;
		}
		if (at == end || cell + shift >= limit) { break; }
		const x = cell + shift;
		const cells = clusterCellsIn(bytes, at, cell);
		const next = nextClusterIn(bytes, at);
		if (x + cells > first) {
			const here = toneAt(tones, toneBase + at);
			const mark = marks.length == 0 ? null : markAt(marks, plain ? r.from + at : docAt(ss, at, true));
			const dim = mark !== null && (mark as Mark).faded;
			const line = mark === null ? null : (mark as Mark).underline;
			if ((here != tone || dim != faded || line != underline) && out.length > 0) {
				pieces.push({ text: out.asString(), tone, faded, underline, hint: false });
				out = [];
			}
			tone = here;
			faded = dim;
			underline = line;
			const lead = bytes[at] as int32;
			if (lead == TAB || x < first || x + cells > limit) {
				out.pushSpaces(Math.min(x + cells, limit) - Math.max(x, first));
			} else if (lead < SPACE || lead == DELETE) {
				out.pushControlPicture(lead);
			} else {
				for (let k = at; k < next; k++) { out.push(bytes[k]); }
				out.pushSpaces(cells - 1);
			}
		}
		cell += cells;
		at = next;
	}
	if (out.length > 0 || pieces.length == 0) { pieces.push({ text: out.asString(), tone, faded, underline, hint: false }); }
	return pieces;
}

function inlayText(text: string, skip: int32, count: int32): string {
	const bytes = text.asBytes();
	const end = bytes.length as int32;
	let out: uint8[] = [];
	let at = 0;
	let cell = 0;
	while (at < end && cell < skip + count) {
		const cells = clusterCellsIn(bytes, at, cell);
		const next = nextClusterIn(bytes, at);
		if (cell >= skip && cell + cells <= skip + count) {
			for (let k = at; k < next; k++) { out.push(bytes[k]); }
		} else if (cell + cells > skip) {
			out.pushSpaces(Math.min(cell + cells, skip + count) - Math.max(cell, skip));
		}
		cell += cells;
		at = next;
	}
	return out.asString();
}

export function rowText(doc: Document, r: VisualRow, left: int32, cols: int32): string {
	let text = "";
	for (const p of rowPieces(doc, r, left, cols, [], 0, [])) { text += p.text; }
	return text;
}

function texts(doc: Document, rows: Readonly<Span<VisualRow>>): string {
	const parts: string[] = [];
	for (const r of rows) { parts.push(doc.slice(r.from, r.to)); }
	return parts.join("|");
}

test "a line wraps after the last space that fits" {
	const d = new Document("one two three four");
	assert texts(d, rowsOf(d, 0, 9)) == "one two |three |four";
	assert texts(d, rowsOf(d, 0, 0)) == "one two three four";
	assert texts(d, rowsOf(d, 0, 18)) == "one two three four";
}

test "a word longer than the width breaks where it overflows" {
	const d = new Document("abcdefghij xy");
	assert texts(d, rowsOf(d, 0, 4)) == "abcd|efgh|ij |xy";
}

test "a wide cluster that does not fit starts the next row" {
	const d = new Document("ab中文");
	const rows = rowsOf(d, 0, 3);
	assert texts(d, rows) == "ab|中|文";
	assert rows[1].cell == 2;
	assert texts(d, rowsOf(d, 0, 1)) == "a|b|中|文";
}

test "an empty line is one row" {
	const d = new Document("a\n\nb");
	const rows = rowsOf(d, 1, 4);
	assert rows.length == 1;
	assert rows[0].from == 2;
	assert rows[0].to == 2;
}

test "an offset at a soft break belongs to the row it starts" {
	const d = new Document("one two three");
	const rows = rowsOf(d, 0, 8);
	assert rowIndexOf(rows, 7) == 0;
	assert rowIndexOf(rows, 8) == 1;
	assert rowIndexOf(rows, 13) == 1;
	assert rows[1].holds(13);
	assert !rows[0].holds(8);
	assert offsetIn(d, rows[0], 20) == 7;
	assert offsetIn(d, rows[1], 20) == 13;
	assert cellIn(d, rows[1], 10) == 2;
}

test "a row splits into pieces where the tone, the fade or the underline changes" {
	const d = new Document("ab cd");
	const rows = rowsOf(d, 0, 0);
	const tones: Tone[] = [Tone.Keyword, Tone.Keyword, Tone.Plain, Tone.String, Tone.String];
	const marks: Mark[] = [
		{ from: 4, to: 5, faded: true, underline: null },
		{ from: 2, to: 5, faded: false, underline: Severity.Hint },
		{ from: 3, to: 4, faded: false, underline: Severity.Error },
	];
	const pieces = rowPieces(d, rows[0], 1, 10, tones.slice(1, 5), 1, marks);
	assert pieces.length == 4;
	assert pieces[0].text == "b" && pieces[0].tone == Tone.Keyword && pieces[0].underline === null;
	assert pieces[1].text == " " && pieces[1].tone == Tone.Plain && pieces[1].underline == Severity.Hint;
	assert pieces[2].text == "c" && pieces[2].tone == Tone.String && !pieces[2].faded && pieces[2].underline == Severity.Error;
	assert pieces[3].text == "d" && pieces[3].faded && pieces[3].underline == Severity.Hint;
}

test "row text expands tabs, pads wide clusters and shows control characters" {
	const d = new Document("a\tb中\u0001\u007f");
	const rows = rowsOf(d, 0, 0);
	assert rowText(d, rows[0], 0, 20) == "a   b中 ␁␡";
	assert rowText(d, rows[0], 1, 4) == "   b";
	assert rowText(d, rows[0], 6, 3) == " ␁␡";
	assert rowText(d, rows[0], 0, 6) == "a   b ";
	const lone = new Document("a\rb\r\n");
	assert lone.lineCount() == 2;
	assert rowText(lone, rowsOf(lone, 0, 0)[0], 0, 5) == "a␍b";
}

function hint(at: int32, text: string, bias: Bias): Inlay {
	return { at, text, bias };
}

test "a hint's cells count toward the row they wrap, and a hint at a break starts the next row" {
	const d = new Document("ab cd ef");
	assert texts(d, rowsOf(d, 0, 6)) == "ab cd |ef";
	assert texts(d, rowsOf(d, 0, 6, [hint(2, "::", Bias.Right)])) == "ab |cd ef";
	const rows = rowsOf(d, 0, 6, [hint(6, "1234", Bias.Right)]);
	assert texts(d, rows) == "ab cd |ef";
	assert rowCells(d, rows[0], [hint(6, "1234", Bias.Right)]) == 6;
	assert cellIn(d, rows[1], 7, [hint(6, "1234", Bias.Right)]) == 5;
}

test "the caret sits after a parameter hint and before a type hint, and a click on a hint lands at its place" {
	const d = new Document("f(1, 2)");
	const hints = [hint(2, "a: ", Bias.Left), hint(5, "b: ", Bias.Left), hint(7, ": T", Bias.Right)];
	const r = rowsOf(d, 0, 0)[0];
	assert cellIn(d, r, 2, hints) == 5 && cellIn(d, r, 5, hints) == 11 && cellIn(d, r, 7, hints) == 13;
	assert cellIn(d, r, 2) == 2 && rowCells(d, r, hints) == 16;
	assert offsetIn(d, r, 3, hints) == 2 && offsetIn(d, r, 5, hints) == 2 && offsetIn(d, r, 6, hints) == 3;
	assert offsetIn(d, r, 14, hints) == 7 && offsetIn(d, r, 30, hints) == 7;
	assert shownCellIn(d, r, 3, hints).hintAt == 2 && shownCellIn(d, r, 6, hints).text == 3 && shownCellIn(d, r, 6, hints).hintAt == -1;
}

test "hints draw as their own pieces, clipped to the columns shown" {
	const d = new Document("f(1, 2)");
	const hints = [hint(2, "a: ", Bias.Left), hint(5, "b: ", Bias.Left), hint(7, ": T", Bias.Right)];
	const r = rowsOf(d, 0, 0)[0];
	const all = rowPieces(d, r, 0, 20, [], 0, [], hints);
	let text = "";
	let hinted = "";
	for (const p of all) {
		text += p.text;
		if (p.hint) { hinted += `[${p.text}]`; }
	}
	assert text == "f(a: 1, b: 2): T" && hinted == "[a: ][b: ][: T]" && all.length == 6;
	const clipped = rowPieces(d, r, 3, 5, [], 0, [], hints);
	assert clipped.length == 2 && clipped[0].text == ": " && clipped[0].hint && clipped[1].text == "1, " && !clipped[1].hint;
}

function seen(doc: Document, rows: Readonly<Span<VisualRow>>, folds: Fold[]): string {
	const parts: string[] = [];
	for (const r of rows) {
		let text = "";
		for (const p of rowPieces(doc, r, 0, 40, [], 0, [], [], folds)) { text += p.text; }
		parts.push(text);
	}
	return parts.join("|");
}

test "a folded block shows as its first line, a placeholder and the rest of its closing line" {
	const d = new Document("if (x) {\n  a;\n  b;\n}\nc");
	const folds: Fold[] = [{ from: 8, to: 19 }];
	const rows = rowsOf(d, 2, 0, [], folds);
	assert rows.length == 1 && rows[0].line == 0 && rows[0].from == 0 && rows[0].to == 20;
	assert seen(d, rows, folds) == "if (x) {⋯}";
	assert seen(d, rowsOf(d, 0, 9, [], folds), folds) == "if (x) |{⋯}";
	assert seen(d, rowsOf(d, 4, 9, [], folds), folds) == "c";
}

test "the caret sits before the placeholder at the fold's start and after it at the fold's end" {
	const d = new Document("if (x) {\n  a;\n  b;\n}\nc");
	const folds: Fold[] = [{ from: 8, to: 19 }];
	const r = rowsOf(d, 0, 0, [], folds)[0];
	assert cellIn(d, r, 8, [], folds) == 8 && cellIn(d, r, 19, [], folds) == 9 && rowCells(d, r, [], folds) == 10;
	const placeholder = shownCellIn(d, r, 8, [], folds);
	assert placeholder.hintAt == 8 && placeholder.fold && !shownCellIn(d, r, 9, [], folds).fold;
	assert offsetIn(d, r, 8, [], folds) == 8 && offsetIn(d, r, 9, [], folds) == 19 && offsetIn(d, r, 30, [], folds) == 20;
	assert textOffsetIn(d, r, 8, folds) == 19 && textOffsetIn(d, r, 3, folds) == 3;
}

test "tones index the bytes left shown, and hints inside a fold are dropped" {
	const d = new Document("if (x) {\n  a;\n  b;\n}\nc");
	const folds: Fold[] = [{ from: 8, to: 19 }];
	const tones: Tone[] = [];
	for (let k = 0; k < 11; k++) { tones.push(k == 8 || k == 10 ? Tone.Keyword : Tone.Plain); }
	const close = rowPieces(d, rowsOf(d, 0, 0, [], folds)[0], 0, 40, tones, 0, [], [], folds);
	assert close[close.length - 1].text == "}" && close[close.length - 1].tone == Tone.Keyword;
	const c = rowPieces(d, rowsOf(d, 4, 0, [], folds)[0], 0, 40, tones, 0, [], [], folds);
	assert c[0].text == "c" && c[0].tone == Tone.Keyword;
	const hints = [hint(12, ": T", Bias.Right), hint(20, "!", Bias.Right)];
	let text = "";
	for (const p of rowPieces(d, rowsOf(d, 0, 0, hints, folds)[0], 0, 40, [], 0, [], hints, folds)) { text += p.text; }
	assert text == "if (x) {⋯}!";
}
