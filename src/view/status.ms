import { Document } from "../model/document";
import { LineTarget, targetLine } from "../model/goto";
import { Selections, cursorAt, primaryRange, single, span } from "../model/selection";
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

export function goToHelp(doc: Document, selections: Selections, t: LineTarget | null): string {
	if (t === null) {
		const place = caretPlace(doc, single(selections.primaryRange().head)).split(":");
		return `Current line ${place[0]} of ${doc.lineCount()}, character ${place[1]}`;
	}
	const target = t as LineTarget;
	const line = doc.targetLine(target) + 1;
	if (target.relative != 0) {
		return `Go to line ${line} (${target.relative > 0 ? "+" : ""}${target.relative} from current)`;
	}
	return target.character > 0 ? `Go to line ${line}, character ${target.character}` : `Go to line ${line}`;
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

test "the go-to help names the target line, or the current one when there is none" {
	const doc = new Document("a
bc
d");
	const at = single(3);
	assert goToHelp(doc, at, null) == "Current line 2 of 3, character 2";
	assert goToHelp(doc, at, { line: 9, character: 0, relative: 0 }) == "Go to line 3";
	assert goToHelp(doc, at, { line: 1, character: 4, relative: 0 }) == "Go to line 1, character 4";
	assert goToHelp(doc, at, { line: 1, character: 0, relative: -1 }) == "Go to line 1 (-1 from current)";
	assert goToHelp(doc, at, { line: 3, character: 0, relative: 1 }) == "Go to line 3 (+1 from current)";
}
