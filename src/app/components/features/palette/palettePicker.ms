import { TextSpan } from "../../../../../../neon/src/render/hostTypes";
import { Style } from "../../../../../../neon/src/render/style";
import { Command } from "../../../../model/commands";
import { Palette } from "../../../../model/palette";
import { Keymap } from "../../../../input/keymap";
import { FOREGROUND, MUTED } from "../../../theme";
import { Row } from "../../content/lineRow";
import { cellsOf, clipped, matchedSpans } from "../completion/completionMenu";

const KEY_GAP: int32 = 2;
const MIN_COLUMNS: int32 = 30;
const MAX_COLUMNS: int32 = 70;

export function paletteOf(
	table: Map<string, Command>,
	keymap: Keymap,
	modal: Keymap[],
	changed: () => void,
): Palette {
	const hidden = new Set<string>();
	for (const keys of modal) {
		for (const name of keys.commands()) { hidden.add(name); }
	}
	const names: string[] = [];
	for (const name of table) {
		if (!hidden.has(name)) { names.push(name); }
	}
	return new Palette(names, keymap.firstKeys(), changed);
}

export function paletteColumns(palette: Palette): int32 {
	let titles = 0;
	let keys = 0;
	for (const c of palette.all()) {
		titles = Math.max(titles, cellsOf(c.title));
		keys = Math.max(keys, cellsOf(c.key));
	}
	return Math.min(MAX_COLUMNS, Math.max(MIN_COLUMNS, titles + KEY_GAP + keys));
}

export function paletteRows(palette: Palette, top: int32, count: int32, columns: int32): Row[] {
	const rows: Row[] = [];
	const listed = palette.rows();
	const end = Math.min(listed.length as int32, top + count);
	const base: Style = { color: FOREGROUND };
	const matched: Style = { color: FOREGROUND, textDecorationLine: "underline", textDecorationColor: FOREGROUND };
	for (let k = top; k < end; k++) {
		const c = palette.command(listed[k].index);
		const keyCells = cellsOf(c.key);
		const title = clipped(c.title, columns - keyCells - KEY_GAP);
		const spans: TextSpan[] = [];
		matchedSpans(title, listed[k].positions, 0, base, matched, spans);
		spans.push({ text: " ".repeat(columns - cellsOf(title) - keyCells), style: base });
		if (keyCells > 0) { spans.push({ text: c.key, style: { color: MUTED } }); }
		rows.push({ spans });
	}
	return rows;
}

when (testBuild) {
	import { commands } from "../../../../model/commands";
	import { completionKeymap, defaultKeymap, listKeymap, signatureKeymap } from "../../../../input/keymap";

	test "every command but those of an open list is offered, each row its title, then its first key muted" {
		const modal = [completionKeymap(), listKeymap(), signatureKeymap(true)];
		const palette = paletteOf(commands(), defaultKeymap(), modal, (): void => {});
		const offered = new Set<string>();
		for (const c of palette.all()) { offered.add(c.name); }
		assert offered.has("palette") && offered.has("toggleComments") && offered.has("showCompletions");
		assert !offered.has("confirmCompletion") && !offered.has("listNext") && !offered.has("hideSignatureHelp");
		palette.open();
		palette.search("toggle comments");
		const columns = paletteColumns(palette);
		const row = paletteRows(palette, 0, 1, columns)[0].spans;
		assert row[0].text == "toggle comments" && row[0].style.textDecorationLine == "underline";
		const key = row[row.length - 1];
		assert key.text == "ctrl+/" && key.style.color == MUTED;
		let cells = 0;
		for (const s of row) { cells += cellsOf(s.text); }
		assert cells == columns;
	}
}
