import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { Accessor, createSignal } from "../../../../../../neon/src/core/signal";
import { List, createList } from "../../../../../../neon/src/core/list";
import { ForList, Show } from "../../../../../../neon/src/macros/ui/flow";
import { PixelRatio } from "../../../../../../neon/src/api/pixelRatio";
import { View, ViewHandle } from "../../../../../../neon/src/components/primitives";
import { Editor } from "../../../../model/editor";
import {
	Clip,
	Context,
	Gesture,
	commands,
	drag,
	insertText,
	press,
} from "../../../../model/commands";
import { Outcome, defaultKeymap } from "../../../../input/keymap";
import { Viewport } from "../../../../view/viewport";
import { VisualRow, cellIn, offsetIn, rowIndexOf, rowsOf } from "../../../../view/wrap";
import { Syntax } from "../../../../syntax/syntax";
import { FONT_SIZE } from "../../../theme";
import { Box, Overlay } from "../../ui/overlay";
import { LineRow, Row } from "../../content/lineRow";
import { Preedit } from "../../content/preedit";
import { FindBar } from "../find/findBar";
import { createFinder } from "../find/finder";
import { createBlink } from "./blink";
import { Grid, framed, gutterWidth, painted } from "./paint";

const PROBE = "MMMMMMMMMM";
const MULTI_CLICK_MS: float64 = 400;

function printable(text: string): boolean {
	return text.length > 0 && text.charCodeAt(0) >= 32 && text.charCodeAt(0) != 127;
}

function fill<T>(list: List<T>, items: T[]): void {
	while (list.length() > items.length) { list.remove(list.length() - 1); }
	for (let i = 0; i < items.length; i++) {
		if (i < list.length()) { list.set(i, items[i]); } else { list.push(items[i]); }
	}
}

export function EditorPane(props: {
	editor: Editor;
	syntax: Syntax | null;
	clip: Clip;
	save: (text: string) => void;
	fail: (message: string) => void;
}): NeonNode {
	const { editor, syntax, clip, fail } = props;
	const doc = editor.doc;
	const table = commands();
	const keymap = defaultKeymap();
	const finder = createFinder(editor);
	const blink = createBlink();
	let area: ViewHandle | null = null;
	let view: Viewport = { line: 0, sub: 0, left: 0, rows: 0, cols: 0, pending: 0 };
	let columns = 0;
	let wrap = false;
	let frame: VisualRow[] = [];
	let gesture: Gesture | null = null;
	let lastPress = 0.0;
	let lastOffset = -1;
	let clicks = 0;
	let grid: Grid = { cellWidth: 0, rowHeight: 0 };
	const [drawn, setDrawn] = createSignal<Grid>(grid);
	const [caret, setCaret] = createSignal<Box>({ x: 0, y: 0, width: 0, height: 0, color: "" });
	const [preedit, setPreedit] = createSignal<string>("");
	const rows: List<Row> = createList<Row>([]);
	const shades: List<Box> = createList<Box>([]);
	const carets: List<Box> = createList<Box>([]);

	const wrapWidth = (): int32 => wrap ? view.cols : 0;
	const rowsIn = (line: int32): int32 => rowsOf(doc, line, wrapWidth()).length as int32;

	const fit = (): void => {
		const cols = columns - gutterWidth(doc.lineCount());
		if (view.cols != cols) { view = view.resized(view.rows, cols, doc.lineCount(), rowsIn); }
	};

	const paint = (): void => {
		fit();
		frame = framed(doc, view, wrapWidth());
		const p = painted(doc, editor.selections, frame, view, syntax, grid);
		fill(rows, p.rows);
		fill(shades, p.shades);
		fill(carets, p.carets);
		if (p.primary !== null) { setCaret(p.primary); }
		blink.restart();
	};

	const reveal = (): void => {
		fit();
		const head = editor.selections.ranges[editor.selections.primary].head;
		const line = doc.lineOf(head);
		const lineRows = rowsOf(doc, line, wrapWidth());
		const k = rowIndexOf(lineRows, head);
		view = view.revealed(line, k, doc.lineCount(), rowsIn);
		if (!wrap) { view = view.revealedCell(cellIn(doc, lineRows[k], head)); }
		paint();
	};

	const focus = (): void => {
		if (area !== null) { (area as ViewHandle).focus(); }
	};

	const cx: Context = {
		pageRows: (): int32 => Math.max(1, view.rows - 1),
		wrapWidth,
		toggleWrap: (): void => {
			wrap = !wrap;
			view = { ...view, sub: 0, left: 0 };
		},
		clip: {
			write: clip.write,
			read: (done: (text: string) => void): void => {
				clip.read((pasted: string): void => {
					done(pasted);
					reveal();
				});
			},
		},
		save: props.save,
		findBar: finder.open,
		findAgain: finder.again,
	};

	const layout = (e: NeonEvent): void => {
		if (e.width <= 0 || e.height <= 0) { return; }
		if (area === null) {
			fail("the editor laid out before its handle arrived");
			return;
		}
		const probe = (area as ViewHandle).measureText(PROBE, { fontSize: FONT_SIZE });
		const ratio = PixelRatio.get();
		const cellPx = Math.round(probe.width / PROBE.length * ratio);
		const rowPx = Math.round(probe.height * ratio);
		if (cellPx <= 0 || rowPx <= 0) {
			fail(`cell ${probe.width / PROBE.length}x${probe.height} is not a grid size`);
			return;
		}
		grid = { cellWidth: cellPx / ratio, rowHeight: rowPx / ratio };
		setDrawn(grid);
		columns = Math.floor(PixelRatio.getPixelSizeForLayoutSize(e.width) / cellPx) as int32;
		const heightPx = PixelRatio.getPixelSizeForLayoutSize(e.height);
		view = { ...view, rows: Math.max(1, Math.floor(heightPx / rowPx) as int32) };
		fit();
		view = view.resized(view.rows, view.cols, doc.lineCount(), rowsIn);
		paint();
	};

	const run = (name: string): void => {
		const command = table.get(name);
		if (command === undefined) {
			fail(`the keymap names "${name}", which is no command`);
			return;
		}
		command(editor, cx);
		reveal();
	};

	const typed = (e: NeonEvent): void => {
		if (e.isComposing) { return; }
		const r = keymap.feed({
			key: e.key,
			ctrl: e.ctrlKey,
			alt: e.altKey,
			shift: e.shiftKey,
			meta: e.metaKey,
		});
		if (r.outcome == Outcome.Run) { run(r.command); }
		else if (r.outcome == Outcome.Unbound && printable(e.text)) {
			insertText(editor, e.text);
			reveal();
		}
	};

	const committed = (e: NeonEvent): void => {
		setPreedit("");
		if (e.text == "") { return; }
		insertText(editor, e.text);
		reveal();
	};

	const offsetAt = (e: NeonEvent): int32 => {
		const i = Math.floor(Math.max(0, e.locationY) / grid.rowHeight) as int32;
		if (frame.length == 0 || i >= (frame.length as int32)) { return doc.length(); }
		const textX = gutterWidth(doc.lineCount()) * grid.cellWidth;
		const cell = Math.round((Math.max(0, e.locationX) - textX) / grid.cellWidth) as int32;
		return offsetIn(doc, frame[i], view.left + Math.max(0, cell));
	};

	const pressed = (e: NeonEvent): void => {
		if (grid.cellWidth <= 0 || e.button != 1) { return; }
		const offset = offsetAt(e);
		const now = Date.now();
		clicks = now - lastPress < MULTI_CLICK_MS && offset == lastOffset ? clicks % 3 + 1 : 1;
		lastPress = now;
		lastOffset = offset;
		gesture = press(editor, offset, clicks, e.shiftKey, e.altKey);
		paint();
	};

	const dragged = (e: NeonEvent): void => {
		if (gesture === null || !e.pressed) { return; }
		drag(editor, gesture as Gesture, offsetAt(e));
		reveal();
	};

	const widest = (): int32 => {
		let most = 0;
		for (const r of frame) { most = Math.max(most, cellIn(doc, r, r.to)); }
		return most;
	};

	const wheeled = (e: NeonEvent): void => {
		const sideways = e.deltaX != 0 ? e.deltaX : e.shiftKey ? -e.deltaY : 0;
		const next = sideways != 0
			? (wrap ? view : view.slid(sideways, widest()))
			: view.wheeled(e.deltaY, doc.lineCount(), rowsIn);
		const moved = next.line != view.line || next.sub != view.sub || next.left != view.left;
		view = next;
		if (moved) { paint(); }
	};

	return <View style={{ flexGrow: 1, flexShrink: 1, flexBasis: 0 }}>
		<View
			style={{ flexGrow: 1, flexShrink: 1, flexBasis: 0, pointerEvents: "box-only" }}
			focusable
			ref={(handle: ViewHandle): void => {
				area = handle;
				handle.focus();
			}}
			imeRect={{
				x: caret().x,
				y: caret().y,
				width: drawn().cellWidth,
				height: drawn().rowHeight,
			}}
			onLayout={layout}
			onKeyDown={typed}
			onTextInput={committed}
			onPreedit={(e: NeonEvent): void => { setPreedit(e.text); }}
			onPointerDown={pressed}
			onPointerMove={dragged}
			onPointerUp={(e: NeonEvent): void => { gesture = null; }}
			onWheel={wheeled}>
			{ForList<Box>({
				each: shades,
				children: (b: Accessor<Box>): NeonNode => <Overlay box={b()} />,
			})}
			{ForList<Row>({
				each: rows,
				children: (r: Accessor<Row>): NeonNode => <LineRow
					row={r()}
					cellWidth={drawn().cellWidth}
					rowHeight={drawn().rowHeight}
				/>,
			})}
			{ForList<Box>({
				each: carets,
				children: (b: Accessor<Box>): NeonNode => <Overlay box={b()} shown={blink.on()} />,
			})}
			<Show when={preedit() != ""}>
				<Preedit text={preedit()} at={caret()} cellWidth={drawn().cellWidth} />
			</Show>
		</View>
		<FindBar finder={finder} moved={reveal} closed={focus} />
	</View>;
}
