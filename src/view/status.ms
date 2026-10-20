import { Document } from "../model/document";
import { Selections, cursorAt, primaryRange, span } from "../model/selection";
import { cellsIn, isTrail, nextClusterIn } from "../text/clusters";

const ELLIPSIS = "…";

export function caretPlace(doc: Document, selections: Selections): string {
	const head = selections.primaryRange().head;
	const line = doc.lineOf(head);
	const before = doc.slice(doc.lineStart(line), head);
	const bytes = before.asBytes();
	let character = 1;
	for (let k = 0; k < bytes.length; k++) {
		if (!isTrail(bytes[k] as int32)) { character += 1; }
	}
	let lines = 0;
	for (const s of selections.ranges) {
		if (s.isEmpty()) { continue; }
		const last = doc.lineOf(s.end());
		lines += last - doc.lineOf(s.start()) + (s.end() != doc.lineStart(last) ? 1 : 0);
	}
	const counts: string[] = [];
	if (selections.ranges.length > 1) { counts.push(`${selections.ranges.length} selections`); }
	if (lines > 1) { counts.push(`${lines} lines`); }
	const place = `${line + 1}:${character}`;
	return counts.length == 0 ? place : `${place} (${counts.join(", ")})`;
}

function cellsOf(text: string): int32 {
	return cellsIn(text.asBytes(), 0, text.byteLength, 0);
}

export function statusLine(left: string, right: string, cols: int32): string {
	const room = cols - cellsOf(right) - 1;
	let shown = left;
	if (cellsOf(shown) > room) {
		const bytes = left.asBytes();
		let from = 0;
		while (from < left.byteLength && cellsIn(bytes, from, left.byteLength, 0) + 1 > room) {
			from = nextClusterIn(bytes, from);
		}
		shown = ELLIPSIS + left.byteSlice(from, left.byteLength);
	}
	return shown + " ".repeat(Math.max(1, cols - cellsOf(shown) - cellsOf(right))) + right;
}

function placeIn(text: string, ranges: Selections): string {
	return caretPlace(new Document(text), ranges);
}

test "the caret's line and character count from one, by code point" {
	assert placeIn("ab\nđệx", { ranges: [cursorAt(9)], primary: 0 }) == "2:4";
	assert placeIn("", { ranges: [cursorAt(0)], primary: 0 }) == "1:1";
}

test "several selections and lines are counted, a selection ending at a line start leaves that line" {
	assert placeIn("a\nb\nc", { ranges: [span(0, 4)], primary: 0 }) == "3:1 (2 lines)";
	assert placeIn("a\nb\nc", { ranges: [span(0, 5)], primary: 0 }) == "3:2 (3 lines)";
	assert placeIn("a\nb\nc", { ranges: [span(0, 1)], primary: 0 }) == "1:2";
	assert placeIn("a\nb\nc", { ranges: [cursorAt(0), cursorAt(2)], primary: 1 }) == "2:1 (2 selections)";
}

test "the left side gives way from its start so the right side stays whole" {
	assert statusLine("a.ms", "1:1", 10) == "a.ms   1:1";
	assert statusLine("dir/file.ms", "1:1", 10) == "…le.ms 1:1";
	assert statusLine("dir/file.ms", "1:1", 3) == "… 1:1";
}
