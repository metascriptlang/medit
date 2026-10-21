import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { Accessor } from "../../../../../../neon/src/core/signal";
import { TextSpan } from "../../../../../../neon/src/render/hostTypes";
import { View } from "../../../../../../neon/src/components/primitives";
import { TabCell, TabEntry, TabHit, stripLeft, tabAt, tabCells } from "../../../../view/tabStrip";
import { BACKGROUND, FOREGROUND, MUTED, PANEL } from "../../../theme";
import { LineRow, Row } from "../../content/lineRow";
import { cellsOf, clipped } from "../completion/completionMenu";

const DIRTY = "●";
const CLOSE = "×";

export struct Strip {
	cells: TabCell[];
	left: int32;
}

export function stripOf(entries: TabEntry[], active: int32, left: int32, width: int32): Strip {
	const cells = tabCells(entries);
	return { cells, left: stripLeft(cells, active, left, width) };
}

export function tabRow(strip: Strip, entries: TabEntry[], active: int32, width: int32): Row {
	const spans: TextSpan[] = [];
	let used = 0;
	for (const c of strip.cells) {
		if (c.to <= strip.left) { continue; }
		if (c.from >= strip.left + width) { break; }
		const on = c.index == active;
		const back = on ? BACKGROUND : PANEL;
		const mark = entries[c.index].dirty ? DIRTY : CLOSE;
		const parts: TextSpan[] = [
			{ text: ` ${c.title}`, style: { color: on ? FOREGROUND : MUTED, backgroundColor: back } },
		];
		if (c.detail.byteLength > 0) { parts.push({ text: ` ${c.detail}`, style: { color: MUTED, backgroundColor: back } }); }
		parts.push({ text: ` ${mark} `, style: { color: on || entries[c.index].dirty ? FOREGROUND : MUTED, backgroundColor: back } });
		let skip = Math.max(0, strip.left - c.from);
		for (const p of parts) {
			const cells = cellsOf(p.text);
			if (skip >= cells) {
				skip -= cells;
				continue;
			}
			let text = p.text;
			if (skip > 0) {
				text = text.slice(skip);
				skip = 0;
			}
			text = clipped(text, width - used);
			if (text.byteLength == 0) { break; }
			spans.push({ text, style: p.style });
			used += cellsOf(text);
		}
	}
	if (used < width) { spans.push({ text: " ".repeat(width - used), style: { backgroundColor: PANEL } }); }
	return { spans };
}

export function TabBar(props: {
	row: Accessor<Row>;
	cellWidth: Accessor<float64>;
	rowHeight: Accessor<float64>;
	hit: (column: int32) => TabHit | null;
	activate: (index: int32) => void;
	close: (index: int32) => void;
}): NeonNode {
	let origin = 0.0;
	return <View
		style={{ height: props.rowHeight(), backgroundColor: PANEL }}
		onLayout={(e: NeonEvent): void => { origin = e.x; }}
		onPointerDown={(e: NeonEvent): void => {
			if (props.cellWidth() <= 0) { return; }
			const found = props.hit(Math.floor((e.x - origin) / props.cellWidth()) as int32);
			if (found === null) { return; }
			const h = found as TabHit;
			if (h.close) { props.close(h.index); } else { props.activate(h.index); }
		}}
	>
		<LineRow row={props.row()} cellWidth={props.cellWidth()} rowHeight={props.rowHeight()} />
	</View>;
}

export function hitIn(strip: Strip, column: int32): TabHit | null {
	return tabAt(strip.cells, column + strip.left);
}

when (testBuild) {
	test "the row shows each tab's name, a close mark or a dirty dot, and fills the width" {
		const entries: TabEntry[] = [{ path: "src/a.ms", dirty: false }, { path: "src/b.ms", dirty: true }];
		const strip = stripOf(entries, 0, 0, 30);
		const row = tabRow(strip, entries, 0, 30);
		let text = "";
		for (const s of row.spans) { text += s.text; }
		assert text == " a.ms × " + " b.ms ● " + " ".repeat(14);
		assert row.spans[0].style.backgroundColor == BACKGROUND && row.spans[2].style.backgroundColor == PANEL;
	}

	test "a scrolled strip cuts the first tab and keeps the clicked column on its tab" {
		const entries: TabEntry[] = [{ path: "aaaa.ms", dirty: false }, { path: "bbbb.ms", dirty: false }];
		const strip = stripOf(entries, 1, 0, 15);
		assert strip.left == 7;
		const row = tabRow(strip, entries, 1, 15);
		let text = "";
		for (const s of row.spans) { text += s.text; }
		assert text == "s × " + " bbbb.ms × ";
		assert (hitIn(strip, 0) as TabHit).index == 0 && (hitIn(strip, 4) as TabHit).index == 1;
		assert (hitIn(strip, 13) as TabHit).close && !(hitIn(strip, 12) as TabHit).close;
	}
}
