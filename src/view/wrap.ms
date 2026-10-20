import { Document } from "../model/document";
import { cellsBetween, offsetAtCell, prevCluster } from "../model/motion";
import { clusterCellsIn, nextClusterIn } from "../text/clusters";
import { Tone } from "./tone";

const TAB: int32 = 9;
const SPACE: int32 = 32;
const DELETE: int32 = 0x7F;

export struct Piece {
	text: string;
	tone: Tone;
}

export struct VisualRow {
	line: int32;
	from: int32;
	to: int32;
	cell: int32;
	last: boolean;
}

export function rowsOf(doc: Document, line: int32, width: int32): Vec<VisualRow> {
	const start = doc.lineStart(line);
	let rows: Vec<VisualRow> = [];
	if (width <= 0) {
		rows.push({ line, from: start, to: doc.lineEnd(line), cell: 0, last: true });
		return rows;
	}
	const text = doc.line(line);
	const b = text.asBytes();
	const end = b.length as int32;
	let from = 0;
	let rowCell = 0;
	let at = 0;
	let cell = 0;
	let breakAt = -1;
	let breakCell = 0;
	while (at < end) {
		const w = clusterCellsIn(b, at, cell);
		if (cell + w - rowCell > width && at > from) {
			const soft = breakAt > from;
			const cut = soft ? breakAt : at;
			rows.push({ line, from: start + from, to: start + cut, cell: rowCell, last: false });
			from = cut;
			rowCell = soft ? breakCell : cell;
			breakAt = -1;
			continue;
		}
		const lead = b[at] as int32;
		cell += w;
		at = nextClusterIn(b, at);
		if (lead == SPACE || lead == TAB) {
			breakAt = at;
			breakCell = cell;
		}
	}
	rows.push({ line, from: start + from, to: start + end, cell: rowCell, last: true });
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

export function cellIn(doc: Document, r: VisualRow, offset: int32): int32 {
	return cellsBetween(doc, r.from, offset, r.cell);
}

export function offsetIn(doc: Document, r: VisualRow, cell: int32): int32 {
	const at = offsetAtCell(doc, r.from, r.to, r.cell, cell);
	return !r.last && at == r.to ? prevCluster(doc, r.to) : at;
}

function pushSpaces(out: uint8[], count: int32): void {
	for (let k = 0; k < count; k++) { out.push(SPACE as uint8); }
}

export function rowPieces(
	doc: Document,
	r: VisualRow,
	left: int32,
	cols: int32,
	tones: Readonly<Span<Tone>>,
	base: int32,
): Vec<Piece> {
	let pieces: Vec<Piece> = [];
	let out: uint8[] = [];
	let tone = Tone.Plain;
	const text = doc.slice(r.from, r.to);
	const b = text.asBytes();
	const end = b.length as int32;
	const first = r.cell + left;
	const limit = first + cols;
	let at = 0;
	let cell = r.cell;
	while (at < end && cell < limit) {
		const w = clusterCellsIn(b, at, cell);
		const next = nextClusterIn(b, at);
		if (cell + w > first) {
			const k = r.from + at - base;
			const t = k >= 0 && k < (tones.length as int32) ? tones[k] : Tone.Plain;
			if (t != tone && out.length > 0) {
				pieces.push({ text: out.asString(), tone });
				out = [];
			}
			tone = t;
			const lead = b[at] as int32;
			if (lead == TAB || cell < first || cell + w > limit) {
				pushSpaces(out, Math.min(cell + w, limit) - Math.max(cell, first));
			} else if (lead < SPACE || lead == DELETE) {
				out.push(0xE2 as uint8);
				out.push(0x90 as uint8);
				out.push((lead == DELETE ? 0xA1 : 0x80 + lead) as uint8);
			} else {
				for (let k = at; k < next; k++) { out.push(b[k]); }
				pushSpaces(out, w - 1);
			}
		}
		cell += w;
		at = next;
	}
	if (out.length > 0 || pieces.length == 0) { pieces.push({ text: out.asString(), tone }); }
	return pieces;
}

export function rowText(doc: Document, r: VisualRow, left: int32, cols: int32): string {
	const parts: string[] = [];
	for (const p of rowPieces(doc, r, left, cols, [], 0)) { parts.push(p.text); }
	return parts.join("");
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

test "a row splits into pieces where the tone changes" {
	const d = new Document("ab cd");
	const rows = rowsOf(d, 0, 0);
	const tones: Tone[] = [Tone.Keyword, Tone.Keyword, Tone.Plain, Tone.String, Tone.String];
	const pieces = rowPieces(d, rows[0], 1, 10, tones.slice(1, 5), 1);
	assert pieces.length == 3;
	assert pieces[0].text == "b" && pieces[0].tone == Tone.Keyword;
	assert pieces[1].text == " " && pieces[1].tone == Tone.Plain;
	assert pieces[2].text == "cd" && pieces[2].tone == Tone.String;
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
