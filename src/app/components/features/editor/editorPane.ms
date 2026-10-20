import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { Accessor, createSignal } from "../../../../../../neon/src/core/signal";
import { List, createList } from "../../../../../../neon/src/core/list";
import { ForList, Show } from "../../../../../../neon/src/macros/ui/flow";
import { PixelRatio } from "../../../../../../neon/src/api/pixelRatio";
import { TextInputHandle, View, ViewHandle } from "../../../../../../neon/src/components/primitives";
import { Editor } from "../../../../model/editor";
import { Sel, primaryRange, single, span } from "../../../../model/selection";
import { LineTarget, lineTarget, targetLine, targetOffset } from "../../../../model/goto";
import { Query, matchesIn } from "../../../../model/find";
import { BracketPair, enclosingBrackets } from "../../../../model/brackets";
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
import { Viewport, centered, dragScrollRows } from "../../../../view/viewport";
import { VisualRow, cellIn, offsetIn, rowIndexOf, rowsOf } from "../../../../view/wrap";
import { Syntax } from "../../../../syntax/syntax";
import { CARET, FONT_SIZE, MUTED, PANEL } from "../../../theme";
import { caretPlace, goToHelp, statusLine } from "../../../../view/status";
import { Box, Overlay } from "../../ui/overlay";
import { LineRow, Row } from "../../content/lineRow";
import { Preedit } from "../../content/preedit";
import { FindBar } from "../find/findBar";
import { createFinder } from "../find/finder";
import { GoToBar } from "../goto/goToBar";
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
	path: string;
	syntax: Syntax | null;
	clip: Clip;
	save: (text: string) => string | null;
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
	let areaHeight = 0.0;
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
	const [status, setStatus] = createSignal<Row>({ spans: [] });
	let saved = false;
	let refusal: string | null = null;
	const [goingTo, setGoingTo] = createSignal<boolean>(false);
	const [lineQuery, setLineQuery] = createSignal<string>("");
	let goingFrom: Viewport | null = null;
	let goText = "";

	const wrapWidth = (): int32 => wrap ? view.cols : 0;
	const rowsIn = (line: int32): int32 => rowsOf(doc, line, wrapWidth()).length as int32;

	const fit = (): void => {
		const cols = columns - gutterWidth(doc.lineCount());
		if (view.cols != cols) { view = view.resized(view.rows, cols, doc.lineCount(), rowsIn); }
	};

	const marked = (): Sel[] => {
		const q = finder.searched();
		if (q === null || frame.length == 0) { return []; }
		const n = (q as Query).text.byteLength;
		const to = Math.min(doc.length(), frame[frame.length - 1].to + n);
		return doc.matchesIn(q as Query, frame[0].from, to)
			.map((at: int32): Sel => span(at, at + n));
	};

	const bracketed = (): Sel[] => {
		const s = editor.selections.primaryRange();
		if (!s.isEmpty()) { return []; }
		const found = doc.enclosingBrackets(s.head, s.head);
		if (found === null) { return []; }
		const p = found as BracketPair;
		return [span(p.open, p.open + 1), span(p.close, p.close + 1)];
	};

	const goTarget = (): LineTarget | null =>
		lineTarget(goText, doc.lineOf(editor.selections.primaryRange().head) + 1);

	const report = (): void => {
		const dirty = editor.isDirty();
		const note = refusal !== null ? ` · ${refusal as string}` : saved && !dirty ? " · saved" : "";
		const left = goingFrom !== null
			? ` ${goToHelp(doc, editor.selections, goTarget())}`
			: ` ${props.path}${dirty ? " ●" : ""}${note}`;
		const text = statusLine(left, `${caretPlace(doc, editor.selections)} `, columns);
		setStatus({ spans: [{ text, style: { color: refusal !== null ? CARET : MUTED } }] });
	};

	const paint = (): void => {
		fit();
		frame = framed(doc, view, wrapWidth());
		const p = painted(doc, editor.selections, marked(), bracketed(), frame, view, syntax, grid);
		fill(rows, p.rows);
		fill(shades, p.shades);
		fill(carets, p.carets);
		if (p.primary !== null) { setCaret(p.primary); }
		blink.restart();
		report();
	};

	const reveal = (): void => {
		fit();
		const head = editor.selections.primaryRange().head;
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
		save: (text: string): string | null => {
			refusal = props.save(text);
			saved = refusal === null;
			return refusal;
		},
		findBar: finder.open,
		findAgain: finder.again,
		goToLine: (): void => {
			goingFrom = view;
			setGoingTo(true);
			paint();
		},
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
		areaHeight = e.height;
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
		if (frame.length == 0) { return doc.length(); }
		const bottom = frame[frame.length - 1];
		if (i >= (frame.length as int32) && bottom.last && bottom.line == doc.lineCount() - 1) {
			return doc.length();
		}
		const textX = gutterWidth(doc.lineCount()) * grid.cellWidth;
		const cell = Math.round((Math.max(0, e.locationX) - textX) / grid.cellWidth) as int32;
		return offsetIn(doc, frame[Math.min(i, (frame.length as int32) - 1)], view.left + Math.max(0, cell));
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
		const rows = dragScrollRows(e.locationY, areaHeight, grid.rowHeight);
		if (rows != 0) {
			view = view.nudged(rows, doc.lineCount(), rowsIn);
			frame = framed(doc, view, wrapWidth());
		}
		drag(editor, gesture as Gesture, offsetAt(e));
		reveal();
	};

	const goClosed = (): void => {
		goingFrom = null;
		goText = "";
		setLineQuery("");
		setGoingTo(false);
		focus();
	};

	const goChanged = (text: string): void => {
		goText = text;
		setLineQuery(text);
		const t = goTarget();
		if (t !== null) { view = view.centered(doc.targetLine(t as LineTarget), doc.lineCount(), rowsIn); }
		paint();
	};

	const goConfirmed = (): void => {
		const t = goTarget();
		goClosed();
		if (t !== null) {
			const at = doc.targetOffset(t as LineTarget);
			editor.select(single(at));
			view = view.centered(doc.lineOf(at), doc.lineCount(), rowsIn);
		}
		reveal();
	};

	const goCancelled = (): void => {
		if (goingFrom !== null) { view = goingFrom as Viewport; }
		goClosed();
		paint();
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
		<GoToBar
			shown={goingTo()}
			query={lineQuery()}
			attach={(input: TextInputHandle): void => { input.focus(); }}
			changed={goChanged}
			confirmed={goConfirmed}
			cancelled={goCancelled}
		/>
		<View style={{ height: drawn().rowHeight, backgroundColor: PANEL }}>
			<LineRow row={status()} cellWidth={drawn().cellWidth} rowHeight={drawn().rowHeight} />
		</View>
	</View>;
}
