import { NeonNode } from "../../../../../../neon/src/render/node";
import { Accessor } from "../../../../../../neon/src/core/signal";
import { List } from "../../../../../../neon/src/core/list";
import { ForList, Show } from "../../../../../../neon/src/macros/ui/flow";
import { View } from "../../../../../../neon/src/components/primitives";
import { TextSpan } from "../../../../../../neon/src/render/hostTypes";
import { Style } from "../../../../../../neon/src/render/style";
import { Choice, Completion } from "../../../../model/completion";
import { charsOf } from "../../../../text/fuzzy";
import { Tone } from "../../../../view/tone";
import { FIELD, MUTED, colorOf } from "../../../theme";
import { Box, Overlay } from "../../ui/overlay";
import { LineRow, Row } from "../../content/lineRow";

export const MENU_ROWS: int32 = 12;
export const MENU_INSET: int32 = 1;
const MAX_COLUMNS: int32 = 60;
export const MENU_BORDER: float64 = 1;
const ELLIPSIS = "…";

const KIND_METHOD: int32 = 2;
const KIND_FUNCTION: int32 = 3;
const KIND_CONSTRUCTOR: int32 = 4;
const KIND_FIELD: int32 = 5;
const KIND_VARIABLE: int32 = 6;
const KIND_CLASS: int32 = 7;
const KIND_INTERFACE: int32 = 8;
const KIND_PROPERTY: int32 = 10;
const KIND_ENUM: int32 = 13;
const KIND_KEYWORD: int32 = 14;
const KIND_ENUM_MEMBER: int32 = 20;
const KIND_CONSTANT: int32 = 21;
const KIND_STRUCT: int32 = 22;
const KIND_OPERATOR: int32 = 24;

export function kindTone(kind: int32): Tone {
	return match (kind) {
		KIND_CLASS | KIND_CONSTRUCTOR | KIND_ENUM | KIND_INTERFACE | KIND_STRUCT => Tone.Type,
		KIND_CONSTANT => Tone.Constant,
		KIND_ENUM_MEMBER | KIND_FIELD | KIND_PROPERTY => Tone.Property,
		KIND_FUNCTION | KIND_METHOD => Tone.Function,
		KIND_OPERATOR => Tone.Operator,
		KIND_VARIABLE => Tone.Variable,
		KIND_KEYWORD => Tone.Keyword,
		_ => Tone.Plain,
	};
}

// The label's suffix after it: the detail when it says something the label does not.
function suffixOf(c: Completion): string {
	const detail = c.detail.split("\n")[0].trim();
	return detail.byteLength > 0 && detail != c.label ? ` ${detail}` : "";
}

export function cellsOf(text: string): int32 { return charsOf(text).text.length as int32; }

// The columns the widest choice needs, the label and its suffix, up to the menu's limit.
export function menuColumns(items: Completion[], choices: Choice[]): int32 {
	let widest = 1;
	for (const choice of choices) {
		const c = items[choice.index];
		widest = Math.max(widest, cellsOf(c.label) + cellsOf(suffixOf(c)));
		if (widest >= MAX_COLUMNS) { return MAX_COLUMNS; }
	}
	return widest;
}

function labelSpans(c: Completion, positions: int32[], spans: TextSpan[]): int32 {
	const shift = c.label.byteIndexOf(c.filterText) as int32;
	const base: Style = c.deprecated
		? { color: MUTED, textDecorationLine: "line-through", textDecorationColor: MUTED }
		: { color: colorOf(kindTone(c.kind)) };
	const color = base.color as string;
	const matched: Style = { color, textDecorationLine: c.deprecated ? "underline line-through" : "underline", textDecorationColor: color };
	return matchedSpans(c.label, positions, shift, base, matched, spans);
}

export function matchedSpans(text: string, positions: int32[], shift: int32, base: Style, matched: Style, spans: TextSpan[]): int32 {
	const chars = charsOf(text);
	let run = "";
	let lit = false;
	for (let i = 0; i < (chars.text.length as int32); i++) {
		const hit = shift >= 0 && positions.includes(chars.at[i] - shift);
		if (hit != lit && run.byteLength > 0) {
			spans.push({ text: run, style: lit ? matched : base });
			run = "";
		}
		lit = hit;
		run += chars.text[i];
	}
	if (run.byteLength > 0) { spans.push({ text: run, style: lit ? matched : base }); }
	return chars.text.length as int32;
}

export function clipped(text: string, cells: int32): string {
	const chars = charsOf(text).text;
	if ((chars.length as int32) <= cells) { return text; }
	return cells <= 0 ? "" : chars.slice(0, cells - 1).join("") + ELLIPSIS;
}

// The rows of `count` choices from `top`, each its label, its matched characters underlined,
// then the suffix muted, cut to `columns`.
export function menuRows(items: Completion[], choices: Choice[], top: int32, count: int32, columns: int32): Row[] {
	const rows: Row[] = [];
	const end = Math.min(choices.length as int32, top + count);
	for (let k = top; k < end; k++) {
		const c = items[choices[k].index];
		const spans: TextSpan[] = [];
		const used = labelSpans(c, choices[k].positions, spans);
		const suffix = clipped(suffixOf(c), columns - used);
		if (suffix.byteLength > 0) { spans.push({ text: suffix, style: { color: MUTED } }); }
		rows.push({ spans });
	}
	return rows;
}

// The first choice shown so that `selected` is in view, moving the window as little as it can.
export function scrolledTop(top: int32, selected: int32, count: int32, total: int32): int32 {
	let next = Math.min(top, Math.max(0, total - count));
	if (selected < next) { next = selected; }
	if (selected >= next + count) { next = selected - count + 1; }
	return Math.max(0, next);
}

export struct Placement {
	box: Box;
	rows: int32;
	above: boolean;
}

// Below the row the word is on, unless the menu does not fit there and there is more room
// above; then as many rows as the side it is on has room for.
export function menuPlaced(
	columns: int32, wanted: int32, x: float64, row: int32, viewRows: int32,
	rowHeight: float64, cellWidth: float64, areaWidth: float64, color: string,
): Placement {
	const below = viewRows - row - 1;
	const above = wanted > below && row > below;
	const rows = Math.max(1, Math.min(wanted, above ? row : below));
	const width = (columns + 2 * MENU_INSET) * cellWidth + 2 * MENU_BORDER;
	const height = rows * rowHeight + 2 * MENU_BORDER;
	return {
		box: {
			x: Math.max(0, Math.min(x - MENU_INSET * cellWidth - MENU_BORDER, areaWidth - width)),
			y: above ? row * rowHeight - height : (row + 1) * rowHeight,
			width,
			height,
			color,
		},
		rows,
		above,
	};
}

export function CompletionMenu(props: {
	shown: Accessor<boolean>;
	box: Accessor<Box>;
	selected: Accessor<Box>;
	rows: List<Row>;
	cellWidth: Accessor<float64>;
	rowHeight: Accessor<float64>;
}): NeonNode {
	return <Show when={props.shown()}>
		<View
			style={{
				position: "absolute",
				left: props.box().x,
				top: props.box().y,
				width: props.box().width,
				height: props.box().height,
				paddingLeft: MENU_INSET * props.cellWidth(),
				backgroundColor: props.box().color,
				borderColor: FIELD,
				borderWidth: MENU_BORDER,
				overflow: "hidden",
				pointerEvents: "none",
			}}>
			<Overlay box={props.selected()} />
			{ForList<Row>({
				each: props.rows,
				children: (r: Accessor<Row>): NeonNode => <LineRow
					row={r()}
					cellWidth={props.cellWidth()}
					rowHeight={props.rowHeight()}
				/>,
			})}
		</View>
	</Show>;
}

when (testBuild) {
	function item(label: string, detail: string, kind: int32, deprecated: boolean): Completion {
		return {
			label, detail, documentation: "", filterText: label, sortText: null, kind, deprecated,
			newText: label, replaceFrom: 0, replaceTo: 0, insertTo: null, at: 0, extra: [], extraAt: 0,
			resolved: true, raw: "",
		};
	}

	test "a row underlines the matched characters in the label's kind colour and mutes the detail" {
		const items = [item("console", "Console", 6, false), item("const", "const", 14, true)];
		const choices: Choice[] = [{ index: 0, positions: [0, 1, 3] }, { index: 1, positions: [] }];
		assert menuColumns(items, choices) == 15;
		const rows = menuRows(items, choices, 0, 2, 12);
		const first = rows[0].spans;
		assert first.length == 5;
		assert first[0].text == "co" && first[0].style.textDecorationLine == "underline";
		assert first[0].style.color == colorOf(Tone.Variable);
		assert first[1].text == "n" && first[1].style.textDecorationLine === null;
		assert first[2].text == "s" && first[3].text == "ole";
		assert first[4].text == " Con…" && first[4].style.color == MUTED;
		const second = rows[1].spans;
		assert second.length == 1 && second[0].text == "const" && second[0].style.textDecorationLine == "line-through";
	}

	test "the window follows the selection, and the menu goes above only when below is short and above is not" {
		assert scrolledTop(0, 13, 12, 20) == 2;
		assert scrolledTop(5, 3, 12, 20) == 3;
		assert scrolledTop(9, 9, 12, 15) == 3;
		const down = menuPlaced(10, 12, 50, 2, 30, 20, 10, 1000, "");
		assert !down.above && down.rows == 12 && down.box.y == 60 && down.box.x == 39;
		const up = menuPlaced(10, 12, 50, 25, 30, 20, 10, 1000, "");
		assert up.above && up.rows == 12 && up.box.y == 500 - 242;
		const squeezed = menuPlaced(10, 12, 995, 3, 9, 20, 10, 1000, "");
		assert !squeezed.above && squeezed.rows == 5 && squeezed.box.x == 1000 - 122;
	}
}
