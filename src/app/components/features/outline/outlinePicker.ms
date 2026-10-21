import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { Accessor } from "../../../../../../neon/src/core/signal";
import { List } from "../../../../../../neon/src/core/list";
import { ForList, Show } from "../../../../../../neon/src/macros/ui/flow";
import { TextInputHandle, View } from "../../../../../../neon/src/components/primitives";
import { TextSpan } from "../../../../../../neon/src/render/hostTypes";
import { Style } from "../../../../../../neon/src/render/style";
import { MenuMove } from "../../../../model/completer";
import { Outline, OutlineRow } from "../../../../model/outline";
import { Tone } from "../../../../view/tone";
import { PANEL, colorOf } from "../../../theme";
import { Field } from "../../ui/field";
import { Box, Overlay } from "../../ui/overlay";
import { LineRow, Row } from "../../content/lineRow";
import { cellsOf, clipped, matchedSpans } from "../completion/completionMenu";

export const OUTLINE_ROWS: int32 = 16;
export const OUTLINE_PADDING: float64 = 6;
export const OUTLINE_GAP: float64 = 4;
const MIN_COLUMNS: int32 = 30;
const MAX_COLUMNS: int32 = 70;
const INDENT = "  ";

const SYMBOL_METHOD: int32 = 6;
const SYMBOL_CLASS: int32 = 5;
const SYMBOL_PROPERTY: int32 = 7;
const SYMBOL_FIELD: int32 = 8;
const SYMBOL_CONSTRUCTOR: int32 = 9;
const SYMBOL_ENUM: int32 = 10;
const SYMBOL_INTERFACE: int32 = 11;
const SYMBOL_FUNCTION: int32 = 12;
const SYMBOL_VARIABLE: int32 = 13;
const SYMBOL_CONSTANT: int32 = 14;
const SYMBOL_KEY: int32 = 20;
const SYMBOL_ENUM_MEMBER: int32 = 22;
const SYMBOL_STRUCT: int32 = 23;
const SYMBOL_OPERATOR: int32 = 25;
const SYMBOL_TYPE_PARAMETER: int32 = 26;

export function symbolTone(kind: int32): Tone {
	return match (kind) {
		SYMBOL_CLASS | SYMBOL_CONSTRUCTOR | SYMBOL_ENUM | SYMBOL_INTERFACE | SYMBOL_STRUCT | SYMBOL_TYPE_PARAMETER => Tone.Type,
		SYMBOL_METHOD | SYMBOL_FUNCTION => Tone.Function,
		SYMBOL_PROPERTY | SYMBOL_FIELD | SYMBOL_KEY | SYMBOL_ENUM_MEMBER => Tone.Property,
		SYMBOL_VARIABLE => Tone.Variable,
		SYMBOL_CONSTANT => Tone.Constant,
		SYMBOL_OPERATOR => Tone.Operator,
		_ => Tone.Plain,
	};
}

function labelOf(outline: Outline, row: OutlineRow): string {
	const item = outline.item(row.index);
	return INDENT.repeat(item.depth) + item.name;
}

export function outlineColumns(outline: Outline): int32 {
	let widest = MIN_COLUMNS;
	for (const row of outline.rows()) { widest = Math.max(widest, cellsOf(labelOf(outline, row))); }
	return Math.min(MAX_COLUMNS, widest);
}

// The rows of `count` symbols from `top`, each indented by its depth in its kind's colour, the
// matched characters underlined.
export function outlineRows(outline: Outline, top: int32, count: int32, columns: int32): Row[] {
	const rows: Row[] = [];
	const listed = outline.rows();
	const end = Math.min(listed.length as int32, top + count);
	for (let k = top; k < end; k++) {
		const item = outline.item(listed[k].index);
		const color = colorOf(symbolTone(item.kind));
		const base: Style = { color };
		const matched: Style = { color, textDecorationLine: "underline", textDecorationColor: color };
		const indent = INDENT.repeat(item.depth);
		const spans: TextSpan[] = [{ text: indent, style: base }];
		matchedSpans(clipped(item.name, columns - cellsOf(indent)), listed[k].positions, 0, base, matched, spans);
		rows.push({ spans });
	}
	return rows;
}

export function OutlinePicker(props: {
	shown: Accessor<boolean>;
	box: Accessor<Box>;
	selected: Accessor<Box>;
	rows: List<Row>;
	query: Accessor<string>;
	cellWidth: Accessor<float64>;
	rowHeight: Accessor<float64>;
	attach: (input: TextInputHandle) => void;
	changed: (text: string) => void;
	moved: (m: MenuMove) => void;
	confirmed: () => void;
	cancelled: () => void;
}): NeonNode {
	const key = (e: NeonEvent): void => {
		match (e.key) {
			"ArrowUp" => { props.moved(MenuMove.Previous); }
			"ArrowDown" => { props.moved(MenuMove.Next); }
			"PageUp" => { props.moved(MenuMove.First); }
			"PageDown" => { props.moved(MenuMove.Last); }
			"Enter" => { props.confirmed(); }
			"Escape" => { props.cancelled(); }
			_ => {}
		}
	};
	return <Show when={props.shown()}>
		<View
			style={{
				position: "absolute",
				left: props.box().x,
				top: props.box().y,
				width: props.box().width,
				padding: OUTLINE_PADDING,
				backgroundColor: PANEL,
			}}>
			<Field
				value={props.query()}
				placeholder="symbol"
				ref={props.attach}
				onChangeText={props.changed}
				onKeyDown={key}
			/>
			<View style={{ height: props.box().height, marginTop: OUTLINE_GAP, overflow: "hidden" }}>
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
		</View>
	</Show>;
}

when (testBuild) {
	import { Editor } from "../../../../model/editor";
	import { Document } from "../../../../model/document";
	import { OutlineItem, SymbolProvider } from "../../../../model/outline";

	test "rows indent by depth, take the kind's colour and underline the matched characters" {
		let answer: (found: OutlineItem[] | null) => void = (found: OutlineItem[] | null): void => {};
		const provider: SymbolProvider = {
			ask: (done: (found: OutlineItem[] | null) => void): int32 => {
				answer = done;
				return 1;
			},
			cancel: (id: int32): void => {},
		};
		const outline = new Outline(new Editor(new Document("class Shape { draw() {} }")), provider, (m: string): void => {}, (): void => {});
		outline.open();
		answer([{ name: "Shape", kind: 5, depth: 0, from: 0, to: 25 }, { name: "draw", kind: 6, depth: 1, from: 14, to: 23 }]);
		outline.search("dw");
		assert outlineColumns(outline) == MIN_COLUMNS;
		const rows = outlineRows(outline, 0, 2, 30);
		assert rows.length == 2 && rows[0].spans[1].text == "Shape" && rows[0].spans[1].style.color == colorOf(Tone.Type);
		const draw = rows[1].spans;
		assert draw[0].text == "  " && draw[1].text == "d" && draw[1].style.textDecorationLine == "underline";
		assert draw[2].text == "ra" && draw[3].text == "w" && draw[3].style.color == colorOf(Tone.Function);
	}
}
