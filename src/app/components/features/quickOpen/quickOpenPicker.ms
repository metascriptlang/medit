import { TextSpan } from "../../../../../../neon/src/render/hostTypes";
import { Style } from "../../../../../../neon/src/render/style";
import { QuickOpen } from "../../../../model/quickOpen";
import { FOREGROUND, MUTED } from "../../../theme";
import { Row } from "../../content/lineRow";
import { cellsOf, clipped, matchedSpans } from "../completion/completionMenu";

const MIN_COLUMNS: int32 = 30;
const MAX_COLUMNS: int32 = 80;

function nameStart(path: string): int32 {
	for (let i = (path.byteLength as int32) - 1; i >= 0; i--) {
		if (path.byteAt(i) == "/".code) { return i + 1; }
	}
	return 0;
}

export function quickOpenColumns(width: float64, cellWidth: float64, padding: float64): int32 {
	if (cellWidth <= 0) { return MIN_COLUMNS; }
	const room = Math.floor((width - 2 * padding) / cellWidth) as int32;
	return Math.max(Math.min(MIN_COLUMNS, room), Math.min(MAX_COLUMNS, room));
}

export function fileRow(path: string, positions: int32[], columns: int32): Row {
	const start = nameStart(path);
	const name = path.byteSlice(start, path.byteLength);
	const dir = start > 0 ? path.byteSlice(0, start - 1) : "";
	const base: Style = { color: FOREGROUND };
	const matched: Style = { color: FOREGROUND, textDecorationLine: "underline", textDecorationColor: FOREGROUND };
	const muted: Style = { color: MUTED };
	const mutedMatch: Style = { color: MUTED, textDecorationLine: "underline", textDecorationColor: MUTED };
	const spans: TextSpan[] = [];
	const shownName = clipped(name, columns);
	let used = matchedSpans(shownName, positions.filter((p: int32): boolean => p >= start).map((p: int32): int32 => p - start), 0, base, matched, spans);
	if (dir.byteLength > 0 && used + 2 <= columns) {
		spans.push({ text: " ", style: muted });
		used += 1 + matchedSpans(clipped(dir, columns - used - 1), positions.filter((p: int32): boolean => p < start - 1), 0, muted, mutedMatch, spans);
	}
	if (used < columns) { spans.push({ text: " ".repeat(columns - used), style: muted }); }
	return { spans };
}

export function quickOpenRows(q: QuickOpen, top: int32, count: int32, columns: int32): Row[] {
	const rows: Row[] = [];
	const listed = q.rows();
	const end = Math.min(listed.length as int32, top + count);
	for (let k = top; k < end; k++) {
		rows.push(fileRow(q.path(listed[k]), listed[k].positions, columns));
	}
	return rows;
}

export function switcherRows(paths: string[], most: int32): [Row[], int32] {
	let columns = MIN_COLUMNS;
	for (const p of paths) { columns = Math.max(columns, Math.min(MAX_COLUMNS, cellsOf(p) + 1)); }
	const rows: Row[] = [];
	for (let i = 0; i < Math.min(most, paths.length as int32); i++) { rows.push(fileRow(paths[i], [], columns)); }
	return [rows, columns];
}

when (testBuild) {
	function textOf(r: Row): string {
		let out = "";
		for (const s of r.spans) { out += s.text; }
		return out;
	}

	test "a file row shows the name, then its directory muted, each with its matched characters underlined" {
		const r = fileRow("src/model/tabs.ms", [4, 10, 11], 30);
		assert textOf(r) == "tabs.ms src/model" + " ".repeat(13);
		assert r.spans[0].text == "ta" && r.spans[0].style.textDecorationLine == "underline";
		assert r.spans[1].text == "bs.ms" && r.spans[1].style.textDecorationLine === undefined;
		const underlined = r.spans.filter((s: TextSpan): boolean => s.style.color == MUTED && s.style.textDecorationLine == "underline");
		assert underlined.length == 1 && underlined[0].text == "m";
	}

	test "a file at the root has no directory, and a narrow row cuts the name" {
		assert textOf(fileRow("build.ms", [], 10)) == "build.ms  ";
		assert textOf(fileRow("averyveryverylongname.ms", [], 8)) == "averyve…";
	}

	test "the switcher lists recent files, at least as wide as the picker" {
		const [rows, columns] = switcherRows(["a/b.ms", "c.ms", "d.ms"], 2);
		assert rows.length == 2 && columns == 30 && textOf(rows[0]) == "b.ms a" + " ".repeat(24);
	}
}
