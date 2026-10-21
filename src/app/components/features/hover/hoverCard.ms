import { NeonNode } from "../../../../../../neon/src/render/node";
import { Accessor } from "../../../../../../neon/src/core/signal";
import { List } from "../../../../../../neon/src/core/list";
import { ForList, Show } from "../../../../../../neon/src/macros/ui/flow";
import { View } from "../../../../../../neon/src/components/primitives";
import { TextSpan } from "../../../../../../neon/src/render/hostTypes";
import { Diagnostic, Severity } from "../../../../model/diagnostics";
import { HoverLine, LineKind, hoverOf } from "../../../../view/markdown";
import { Tone } from "../../../../view/tone";
import { FOREGROUND, MUTED, PANEL, FIELD, colorOf, severityColor } from "../../../theme";
import { Box } from "../../ui/overlay";
import { LineRow, Row } from "../../content/lineRow";

const MAX_COLUMNS: int32 = 80;
const MAX_ROWS: int32 = 16;
const INSET_CELLS: int32 = 1;
const GAP: float64 = 2;
const BORDER: float64 = 1;

export struct Card {
	rows: Row[];
	columns: int32;
}

export type Highlight = (source: string, language: string) => Tone[] | null;

function line(text: string, color: string): Row {
	return { spans: [{ text, style: { color } }] };
}

function toned(l: HoverLine, source: string, tones: Tone[]): Row {
	const end = l.at + (l.text.byteLength as int32);
	const spans: TextSpan[] = [];
	let from = l.at;
	while (from < end) {
		let to = from + 1;
		while (to < end && tones[to] == tones[from]) { to++; }
		spans.push({ text: source.byteSlice(from, to), style: { color: colorOf(tones[from]) } });
		from = to;
	}
	return spans.length == 0 ? line("", FOREGROUND) : { spans };
}

function widthOf(r: Row): int32 {
	let n = 0;
	for (const s of r.spans) { n += s.text.length as int32; }
	return n;
}

export function cardOf(diagnostics: Diagnostic[], markdown: string, columns: int32, highlight: Highlight): Card {
	const width = Math.max(1, Math.min(MAX_COLUMNS, columns - 2 * INSET_CELLS));
	const problems: Row[] = [];
	for (const d of diagnostics) {
		const color = severityColor(d.severity);
		for (const l of hoverOf(d.message, width).lines) { problems.push(line(l.text, color)); }
	}
	const hover = hoverOf(markdown, width);
	const tones: (Tone[] | null)[] = [];
	for (const b of hover.blocks) { tones.push(highlight(b.source, b.language)); }
	const info: Row[] = [];
	for (const l of hover.lines) {
		if (l.kind == LineKind.Code) {
			const t = tones[l.block];
			info.push(t === null ? line(l.text, FOREGROUND) : toned(l, hover.blocks[l.block].source, t as Tone[]));
		} else {
			info.push(line(l.text, MUTED));
		}
	}
	let widest = 0;
	for (const r of problems.concat(info)) { widest = Math.max(widest, widthOf(r)); }
	const rule = "─".repeat(widest);
	for (let i = 0; i < (info.length as int32); i++) {
		if (hover.lines[i].kind == LineKind.Rule) { info[i] = line(rule, MUTED); }
	}
	const rows = problems.length > 0 && info.length > 0
		? problems.concat([line(rule, MUTED)]).concat(info)
		: problems.concat(info);
	return { rows: rows.slice(0, MAX_ROWS), columns: widest };
}

export function cardSize(card: Card, rowHeight: float64, cellWidth: float64): [float64, float64] {
	return [(card.columns + 2 * INSET_CELLS) * cellWidth + 2 * BORDER, card.rows.length * rowHeight + 2 * BORDER];
}

export function placed(card: Card, x: float64, rowTop: float64, rowHeight: float64, cellWidth: float64, areaWidth: float64): Box {
	const [width, height] = cardSize(card, rowHeight, cellWidth);
	const above = rowTop - height - GAP;
	return {
		x: Math.max(0, Math.min(x, areaWidth - width)),
		y: above >= 0 ? above : rowTop + rowHeight + GAP,
		width,
		height,
		color: PANEL,
	};
}

export function HoverCard(props: {
	shown: Accessor<boolean>;
	box: Accessor<Box>;
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
				paddingLeft: INSET_CELLS * props.cellWidth(),
				backgroundColor: props.box().color,
				borderColor: FIELD,
				borderWidth: BORDER,
				overflow: "hidden",
				pointerEvents: "none",
			}}>
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

test "a card stacks diagnostics over the hover text, and sits above its row unless there is no room" {
	const d: Diagnostic = { from: 0, to: 1, severity: Severity.Error, message: "bad", source: "", unnecessary: false };
	const plain = (source: string, language: string): Tone[] | null => null;
	const card = cardOf([d], "```ms\nlet x: int32\n```", 40, plain);
	assert card.rows.length == 3;
	assert card.rows[0].spans[0].text == "bad";
	assert card.rows[2].spans[0].text == "let x: int32";
	assert card.columns == 12 && card.rows[1].spans[0].text == "─".repeat(12);
	const up = placed(card, 500, 100, 20, 10, 300);
	assert up.y == 100 - 62 - 2 && up.x == 300 - 142;
	const down = placed(card, 10, 20, 20, 10, 1000);
	assert down.y == 42 && down.x == 10;
}

test "a rule spans the widest line, and a highlighted block colours its code by tone" {
	const keyword = (source: string, language: string): Tone[] | null => {
		if (language != "ms") { return null; }
		const tones: Tone[] = [];
		for (let i = 0; i < (source.byteLength as int32); i++) { tones.push(i < 3 ? Tone.Keyword : Tone.Plain); }
		return tones;
	};
	const card = cardOf([], "```ms\nlet x\n```\n---\nabc", 40, keyword);
	assert card.columns == 5;
	assert card.rows[0].spans.length == 2;
	assert card.rows[0].spans[0].text == "let" && card.rows[0].spans[0].style.color == colorOf(Tone.Keyword);
	assert card.rows[0].spans[1].text == " x";
	assert card.rows[1].spans[0].text == "─".repeat(5);
	assert card.rows[2].spans[0].text == "abc";
}
