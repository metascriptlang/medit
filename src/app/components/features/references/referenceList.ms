import { Document } from "../../../../model/document";
import { Place } from "../../../../model/references";
import { single } from "../../../../model/selection";
import { caretPlace } from "../../../../view/status";
import { filePath } from "../../../../lsp/uri";
import { FOREGROUND, MUTED } from "../../../theme";
import { Row } from "../../content/lineRow";
import { cellsOf, clipped } from "../completion/completionMenu";

const MAX_COLUMNS: int32 = 80;
const GAP = "  ";

// Where each place is: line and character in this document, else the other file's path.
function whereOf(doc: Document, p: Place): string {
	if (p.here !== null) { return caretPlace(doc, single((p.here as [int32, int32])[0])); }
	const path = filePath(p.uri);
	return `${path === null ? p.uri : path as string}:${p.line + 1}:${p.character + 1}`;
}

function textOf(doc: Document, p: Place): string {
	if (p.here === null) { return ""; }
	const line = doc.lineOf((p.here as [int32, int32])[0]);
	return doc.slice(doc.lineStart(line), doc.lineEnd(line)).trim();
}

function whereColumns(doc: Document, places: Place[]): int32 {
	let widest = 0;
	for (const p of places) { widest = Math.max(widest, cellsOf(whereOf(doc, p))); }
	return widest;
}

export function referenceColumns(doc: Document, places: Place[]): int32 {
	let text = 1;
	for (const p of places) { text = Math.max(text, cellsOf(textOf(doc, p))); }
	return Math.min(MAX_COLUMNS, whereColumns(doc, places) + cellsOf(GAP) + text);
}

// The rows of `count` places from `top`: where each is, muted and padded to one width, then
// its line's text.
export function referenceRows(doc: Document, places: Place[], top: int32, count: int32, columns: int32): Row[] {
	const rows: Row[] = [];
	const width = whereColumns(doc, places);
	const end = Math.min(places.length as int32, top + count);
	for (let k = top; k < end; k++) {
		const label = whereOf(doc, places[k]);
		const where = clipped(label + " ".repeat(Math.max(0, width - cellsOf(label))), columns);
		const text = clipped(textOf(doc, places[k]), columns - cellsOf(where) - cellsOf(GAP));
		rows.push({ spans: [{ text: where + GAP, style: { color: MUTED } }, { text, style: { color: FOREGROUND } }] });
	}
	return rows;
}
