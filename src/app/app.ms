import { element } from "../../../neon/src/macros/ui/element";
import { NeonNode } from "../../../neon/src/render/node";
import { NeonEvent } from "../../../neon/src/render/event";
import { Accessor, createSignal } from "../../../neon/src/core/signal";
import { createList, List } from "../../../neon/src/core/list";
import { ForList, Show } from "../../../neon/src/macros/ui/flow";
import { PixelRatio } from "../../../neon/src/api/pixelRatio";
import { TextSpan } from "../../../neon/src/render/hostTypes";
import { Void, View, Text, ViewHandle } from "../../../neon/src/components/primitives";
import { Viewport } from "../view/viewport";
import { VisualRow, cellIn, holds, offsetIn, rowIndexOf, rowText, rowsOf } from "../view/wrap";
import { Document } from "../model/document";
import { Editor } from "../model/editor";
import { Clip, Command, Context, Gesture, commands, drag, insertText, press } from "../model/commands";
import { cellsBetween } from "../model/motion";
import { end, isEmpty, start } from "../model/selection";
import { Outcome, defaultKeymap } from "../input/keymap";

const BACKGROUND = "#1e1e2e";
const FOREGROUND = "#cdd6f4";
const SELECTION = "#45475a";
const CURRENT_LINE = "#2a2b3c";
const GUTTER = "#6c7086";
const GUTTER_CURRENT = "#bac2de";
const CARET = "#f5e0dc";
const PADDING: number = 6;
const FONT_SIZE: number = 14;
const CARET_WIDTH: number = 2;
const PROBE = "MMMMMMMMMM";
const MULTI_CLICK_MS: number = 400;
const BLINK_MS: number = 530;
const MIN_DIGITS: int32 = 3;
const GUTTER_GAP: int32 = 2;

export struct Row {
	spans: TextSpan[];
}

export struct Box {
	x: number;
	y: number;
	w: number;
	h: number;
	color: string;
}

function printable(text: string): boolean {
	return text.length > 0 && text.charCodeAt(0) >= 32 && text.charCodeAt(0) != 127;
}

function fill<T>(list: List<T>, items: T[]): void {
	while (list.length() > items.length) { list.remove(list.length() - 1); }
	for (let i = 0; i < items.length; i++) {
		if (i < list.length()) { list.set(i, items[i]); } else { list.push(items[i]); }
	}
}

export function App(text: string, clip: Clip, fail: (message: string) => void): NeonNode {
	const editor = new Editor(new Document(text));
	const doc = editor.doc;
	const table = commands();
	const keymap = defaultKeymap();
	let area: ViewHandle | null = null;
	let view: Viewport = { line: 0, sub: 0, left: 0, rows: 0, cols: 0, pending: 0 };
	let columns = 0;
	let gutter = 0;
	let wrap = false;
	let frame: VisualRow[] = [];
	let gesture: Gesture | null = null;
	let lastPress = 0.0;
	let lastOffset = -1;
	let clicks = 0;
	let blinkTimer: number = -1;
	const [cellWidth, setCellWidth] = createSignal<number>(0);
	const [rowHeight, setRowHeight] = createSignal<number>(0);
	const [preedit, setPreedit] = createSignal<string>("");
	const [composing, setComposing] = createSignal<boolean>(false);
	const [caretX, setCaretX] = createSignal<number>(0);
	const [caretY, setCaretY] = createSignal<number>(0);
	const [blinkOn, setBlinkOn] = createSignal<boolean>(true);
	const rows: List<Row> = createList<Row>([]);
	const shades: List<Box> = createList<Box>([]);
	const carets: List<Box> = createList<Box>([]);

	const wrapWidth = (): int32 => wrap ? view.cols : 0;
	const rowsIn = (line: int32): int32 => rowsOf(doc, line, wrapWidth()).length as int32;

	function armBlink(): void {
		blinkTimer = setTimeout((): void => {
			setBlinkOn(!blinkOn());
			armBlink();
		}, BLINK_MS);
	}

	function restartBlink(): void {
		if (blinkTimer >= 0) { clearTimeout(blinkTimer); }
		setBlinkOn(true);
		armBlink();
	}

	const fit = (): void => {
		const count = doc.lineCount();
		gutter = Math.max(MIN_DIGITS, `${count}`.length as int32) + GUTTER_GAP;
		if (view.cols != columns - gutter) { view = view.resized(view.rows, columns - gutter, count, rowsIn); }
	};

	const framed = (): VisualRow[] => {
		const count = doc.lineCount();
		const width = wrapWidth();
		const out: VisualRow[] = [];
		for (let line = view.line; line < count && (out.length as int32) < view.rows; line++) {
			const lineRows = rowsOf(doc, line, width);
			for (let k = line == view.line ? view.sub : 0; k < (lineRows.length as int32) && (out.length as int32) < view.rows; k++) {
				out.push(lineRows[k]);
			}
		}
		return out;
	};

	const paint = (): void => {
		fit();
		frame = framed();
		const cw = cellWidth();
		const rh = rowHeight();
		const textX = gutter * cw;
		const digits = gutter - GUTTER_GAP;
		const ranges = editor.selections.ranges;
		const head = ranges[editor.selections.primary].head;
		const current = doc.lineOf(head);
		const lines: Row[] = [];
		for (const r of frame) {
			const number = r.cell == 0 ? `${r.line + 1}`.padStart(digits, " ") : "".padStart(digits, " ");
			lines.push({
				spans: [
					{ text: number + "".padStart(GUTTER_GAP, " "), style: { color: r.line == current ? GUTTER_CURRENT : GUTTER } },
					{ text: rowText(doc, r, view.left, view.cols), style: { color: FOREGROUND } },
				],
			});
		}
		fill(rows, lines);
		const band = (y: int32, from: int32, to: int32, color: string): Box | null => {
			const lo = Math.max(from, view.left);
			const hi = Math.min(to, view.left + view.cols);
			if (hi <= lo) { return null; }
			return { x: textX + (lo - view.left) * cw, y: y * rh, w: (hi - lo) * cw, h: rh, color };
		};
		const lit: Box[] = [];
		const shaded: Box[] = [];
		const placed: Box[] = [];
		const top = frame.length > 0 ? frame[0].from : 0;
		const bottom = frame.length > 0 ? frame[frame.length - 1].to : 0;
		for (const s of ranges) {
			if (s.end() < top || s.start() > bottom + 1) { continue; }
			for (let i = 0; i < (frame.length as int32); i++) {
				const r = frame[i];
				if (r.holds(s.head)) {
					const cell = cellIn(doc, r, s.head) - view.left;
					if (cell >= 0 && cell <= view.cols) {
						placed.push({ x: textX + cell * cw, y: i * rh, w: CARET_WIDTH, h: rh, color: CARET });
					}
					if (s.isEmpty()) { lit.push({ x: textX, y: i * rh, w: view.cols * cw, h: rh, color: CURRENT_LINE }); }
					if (s.head == head) {
						setCaretX(textX + Math.max(0, cell) * cw);
						setCaretY(i * rh);
					}
				}
				const lo = Math.max(s.start(), r.from);
				const hi = Math.min(s.end(), r.to);
				const newline = r.last && s.start() <= r.to && s.end() > r.to;
				if (lo < hi || (newline && lo <= hi)) {
					const from = cellIn(doc, r, lo);
					const to = from + cellsBetween(doc, lo, hi, r.cell + from) + (newline ? 1 : 0);
					const b = band(i, from, to, SELECTION);
					if (b !== null) { shaded.push(b as Box); }
				}
			}
		}
		fill(shades, lit.concat(shaded));
		fill(carets, placed);
		restartBlink();
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
	};

	const layout = (e: NeonEvent): void => {
		if (e.width <= 0 || e.height <= 0) { return; }
		const handle = area;
		if (handle === null) {
			fail("the editor laid out before its handle arrived");
			return;
		}
		const probe = handle.measureText(PROBE, { fontSize: FONT_SIZE });
		const ratio = PixelRatio.get();
		const cellPx = Math.round(probe.width / PROBE.length * ratio);
		const rowPx = Math.round(probe.height * ratio);
		if (cellPx <= 0 || rowPx <= 0) {
			fail(`cell ${probe.width / PROBE.length}x${probe.height} is not a grid size`);
			return;
		}
		setCellWidth(cellPx / ratio);
		setRowHeight(rowPx / ratio);
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
		(command as Command)(editor, cx);
		reveal();
	};

	const typed = (e: NeonEvent): void => {
		if (e.isComposing) { return; }
		const r = keymap.feed({ key: e.key, ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey, meta: e.metaKey });
		if (r.outcome == Outcome.Run) { run(r.command); }
		else if (r.outcome == Outcome.Unbound && printable(e.text)) {
			insertText(editor, e.text);
			reveal();
		}
	};

	const compose = (text: string): void => {
		setPreedit(text);
		setComposing(text != "");
	};

	const committed = (e: NeonEvent): void => {
		compose("");
		if (e.text == "") { return; }
		insertText(editor, e.text);
		reveal();
	};

	const offsetAt = (e: NeonEvent): int32 => {
		const i = Math.floor(Math.max(0, e.locationY) / rowHeight()) as int32;
		if (frame.length == 0 || i >= (frame.length as int32)) { return doc.length(); }
		const cell = Math.round((Math.max(0, e.locationX) - gutter * cellWidth()) / cellWidth()) as int32;
		return offsetIn(doc, frame[i], view.left + Math.max(0, cell));
	};

	const pressed = (e: NeonEvent): void => {
		if (cellWidth() <= 0 || e.button != 1) { return; }
		const offset = offsetAt(e);
		const now = Date.now();
		clicks = now - lastPress < MULTI_CLICK_MS && offset == lastOffset ? clicks % 3 + 1 : 1;
		lastPress = now;
		lastOffset = offset;
		gesture = press(editor, offset, clicks, e.shiftKey, e.altKey);
		paint();
	};

	const dragged = (e: NeonEvent): void => {
		const g = gesture;
		if (g === null || !e.pressed) { return; }
		drag(editor, g as Gesture, offsetAt(e));
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

	const lineRow = (item: Accessor<Row>): NeonNode => {
		return element(
			<Text
				style={{ fontSize: FONT_SIZE, height: rowHeight() }}
				cellWidth={cellWidth()}
				spans={item().spans}
			/>
		);
	};

	const box = (item: Accessor<Box>): NeonNode => {
		return element(
			<View
				style={{
					position: "absolute", left: item().x, top: item().y, width: item().w, height: item().h,
					backgroundColor: item().color, pointerEvents: "none",
				}}
			/>
		);
	};

	const caret = (item: Accessor<Box>): NeonNode => {
		return element(
			<View
				style={{
					position: "absolute", left: item().x, top: item().y, width: item().w, height: item().h,
					backgroundColor: item().color, opacity: blinkOn() ? 1 : 0, pointerEvents: "none",
				}}
			/>
		);
	};

	return element(
		<Void style={{ backgroundColor: BACKGROUND, padding: PADDING }}>
			<View
				style={{ flexGrow: 1, flexShrink: 1, flexBasis: 0, pointerEvents: "box-only" }}
				focusable
				ref={(h: ViewHandle): void => {
					area = h;
					h.focus();
				}}
				imeRect={{ x: caretX(), y: caretY(), width: cellWidth(), height: rowHeight() }}
				onLayout={layout}
				onKeyDown={typed}
				onTextInput={committed}
				onPreedit={(e: NeonEvent): void => { compose(e.text); }}
				onPointerDown={pressed}
				onPointerMove={dragged}
				onPointerUp={(e: NeonEvent): void => { gesture = null; }}
				onWheel={wheeled}>
				{ForList<Box>({ each: shades, children: box })}
				{ForList<Row>({ each: rows, children: lineRow })}
				{ForList<Box>({ each: carets, children: caret })}
				{Show({
					when: composing,
					children: element(
						<View
							style={{
								position: "absolute", left: caretX(), top: caretY(),
								backgroundColor: BACKGROUND, pointerEvents: "none",
							}}>
							<Text
								style={{ fontSize: FONT_SIZE, color: FOREGROUND, height: rowHeight(), textDecorationLine: "underline" }}
								cellWidth={cellWidth()}>
								{preedit()}
							</Text>
						</View>
					),
				})}
			</View>
		</Void>
	);
}
