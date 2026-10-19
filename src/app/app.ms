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
import { Document } from "../model/document";
import { Editor } from "../model/editor";
import { Clip, Command, Context, Gesture, commands, drag, insertText, press } from "../model/commands";
import { columnOf, offsetAtColumn } from "../model/motion";
import { end, isEmpty, start } from "../model/selection";
import { Outcome, defaultKeymap } from "../input/keymap";

const BACKGROUND = "#1e1e2e";
const FOREGROUND = "#cdd6f4";
const SELECTION = "#45475a";
const CARET = "#f5e0dc";
const PADDING: number = 6;
const FONT_SIZE: number = 14;
const CARET_WIDTH: number = 2;
const PROBE = "MMMMMMMMMM";
const MULTI_CLICK_MS: number = 400;

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

function rowOf(text: string): Row {
	return { spans: [{ text, style: { color: FOREGROUND } }] };
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
	let view: Viewport = { top: 0, rows: 0, pending: 0 };
	let gesture: Gesture | null = null;
	let lastPress = 0.0;
	let lastOffset = -1;
	let clicks = 0;
	const [cellWidth, setCellWidth] = createSignal<number>(0);
	const [rowHeight, setRowHeight] = createSignal<number>(0);
	const [preedit, setPreedit] = createSignal<string>("");
	const [composing, setComposing] = createSignal<boolean>(false);
	const [caretX, setCaretX] = createSignal<number>(0);
	const [caretY, setCaretY] = createSignal<number>(0);
	const rows: List<Row> = createList<Row>([]);
	const shades: List<Box> = createList<Box>([]);
	const carets: List<Box> = createList<Box>([]);

	const paint = (): void => {
		const count = doc.lineCount();
		const lines: Row[] = [];
		for (let i = 0; i < view.rows; i++) {
			const line = view.top + i;
			lines.push(rowOf(line < count ? doc.line(line) : ""));
		}
		fill(rows, lines);
		const cw = cellWidth();
		const rh = rowHeight();
		const bottom = Math.min(view.top + view.rows, count) - 1;
		const shaded: Box[] = [];
		const placed: Box[] = [];
		for (const s of editor.selections.ranges) {
			const first = Math.max(doc.lineOf(s.start()), view.top);
			const last = Math.min(doc.lineOf(s.end()), bottom);
			for (let line = first; line <= last && !s.isEmpty(); line++) {
				const from = Math.max(s.start(), doc.lineStart(line));
				const to = Math.min(s.end(), doc.lineEnd(line));
				const fromCol = columnOf(doc, from);
				const wraps = s.end() > doc.lineEnd(line) ? 1 : 0;
				const width = columnOf(doc, to) - fromCol + wraps;
				if (width > 0) { shaded.push({ x: fromCol * cw, y: (line - view.top) * rh, w: width * cw, h: rh, color: SELECTION }); }
			}
			const line = doc.lineOf(s.head);
			if (line >= view.top && line <= bottom) {
				placed.push({ x: columnOf(doc, s.head) * cw, y: (line - view.top) * rh, w: CARET_WIDTH, h: rh, color: CARET });
			}
		}
		fill(shades, shaded);
		fill(carets, placed);
		const head = editor.selections.ranges[editor.selections.primary].head;
		setCaretX(columnOf(doc, head) * cw);
		setCaretY((doc.lineOf(head) - view.top) * rh);
	};

	const reveal = (): void => {
		const head = editor.selections.ranges[editor.selections.primary].head;
		view = view.revealed(doc.lineOf(head), doc.lineCount());
		paint();
	};

	const cx: Context = {
		pageRows: (): int32 => Math.max(1, view.rows - 1),
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
		const heightPx = PixelRatio.getPixelSizeForLayoutSize(e.height);
		view = view.resized(Math.floor(heightPx / rowPx) as int32, doc.lineCount());
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
		const rh = rowHeight();
		const cw = cellWidth();
		const line = view.top + (Math.floor(Math.max(0, e.locationY) / rh) as int32);
		if (line >= doc.lineCount()) { return doc.length(); }
		return offsetAtColumn(doc, line, Math.round(Math.max(0, e.locationX) / cw) as int32);
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

	const wheeled = (e: NeonEvent): void => {
		const next = view.wheeled(e.deltaY, doc.lineCount());
		const moved = next.top != view.top;
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
				{ForList<Box>({ each: carets, children: box })}
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
