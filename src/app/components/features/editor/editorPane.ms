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
import { Syntax, covers } from "../../../../syntax/syntax";
import { Document } from "../../../../model/document";
import { Tone } from "../../../../view/tone";
import { Diagnostic } from "../../../../model/diagnostics";
import { offsetAtCell } from "../../../../model/motion";
import { Session } from "../../../../lsp/session";
import { Span, Target } from "../../../../lsp/server";
import { filePath } from "../../../../lsp/uri";
import { CARET, FONT_SIZE, MUTED, PANEL } from "../../../theme";
import { caretPlace, goToHelp, statusLine } from "../../../../view/status";
import { Box, Overlay } from "../../ui/overlay";
import { LineRow, Row } from "../../content/lineRow";
import { Preedit } from "../../content/preedit";
import { FindBar } from "../find/findBar";
import { createFinder } from "../find/finder";
import { GoToBar } from "../goto/goToBar";
import { HoverCard, cardOf, placed } from "../hover/hoverCard";
import { createBlink } from "./blink";
import { Grid, framed, gutterWidth, painted } from "./paint";

const PROBE = "MMMMMMMMMM";
const MULTI_CLICK_MS: float64 = 400;
const HOVER_DELAY_MS: float64 = 300;
const METASCRIPT = "metascript";

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
	session: Session | null;
	serverNote: string;
}): NeonNode {
	const { editor, syntax, clip, fail, session } = props;
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
	let notice: string | null = null;
	let areaWidth = 0.0;
	const [carded, setCarded] = createSignal<boolean>(false);
	const [cardBox, setCardBox] = createSignal<Box>({ x: 0, y: 0, width: 0, height: 0, color: "" });
	const cardRows: List<Row> = createList<Row>([]);
	let cardOver: Span | null = null;
	let hoverTimer: float64 = -1;
	let hoverAsked = -1;
	let hoverPoint = -1;
	let active: Diagnostic | null = null;

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

	const serverPart = (): string => {
		if (session === null) { return props.serverNote.byteLength > 0 ? ` · ${props.serverNote}` : ""; }
		const s = session as Session;
		const t = s.diagnostics.tally();
		const counts = (t.errors > 0 ? ` · ${t.errors} error${t.errors == 1 ? "" : "s"}` : "")
			+ (t.warnings > 0 ? ` · ${t.warnings} warning${t.warnings == 1 ? "" : "s"}` : "");
		const state = s.status();
		return counts + (state.byteLength > 0 ? ` · ${state}` : "");
	};

	const report = (): void => {
		const dirty = editor.isDirty();
		const loud = refusal !== null ? refusal : notice;
		const note = loud !== null ? ` · ${loud as string}` : saved && !dirty ? " · saved" : "";
		const left = goingFrom !== null
			? ` ${goToHelp(doc, editor.selections, goTarget())}`
			: ` ${props.path}${dirty ? " ●" : ""}${note}${serverPart()}`;
		const text = statusLine(left, `${caretPlace(doc, editor.selections)} `, columns);
		setStatus({ spans: [{ text, style: { color: loud !== null ? CARET : MUTED } }] });
	};

	const visibleDiagnostics = (): Diagnostic[] => {
		if (session === null || frame.length == 0) { return []; }
		return (session as Session).diagnostics.within(doc, frame[0].from, frame[frame.length - 1].to);
	};

	const paint = (): void => {
		fit();
		if (session !== null) { (session as Session).edited(); }
		frame = framed(doc, view, wrapWidth());
		const p = painted(doc, editor.selections, marked(), bracketed(), frame, view, syntax, visibleDiagnostics(), grid);
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

	let hoverSeq = 0;
	let after: (() => void) | null = null;

	const hideCard = (): void => {
		if (hoverTimer >= 0) { clearTimeout(hoverTimer); }
		hoverTimer = -1;
		if (session !== null && hoverAsked >= 0) { (session as Session).cancel(hoverAsked); }
		hoverAsked = -1;
		hoverSeq += 1;
		hoverPoint = -1;
		cardOver = null;
		if (carded()) { setCarded(false); }
	};

	let fenceDoc: Document | null = null;
	let fenceSyntax: Syntax | null = null;
	const highlight = (source: string, language: string): Tone[] | null => {
		if (language != METASCRIPT && !covers(`.${language}`)) { return null; }
		if (fenceSyntax === null) {
			fenceDoc = new Document("");
			fenceSyntax = new Syntax();
		}
		const d = fenceDoc as Document;
		const _old = d.splice({ from: 0, to: d.length(), text: source });
		return (fenceSyntax as Syntax).tonesIn(d, 0, d.length());
	};

	const showCard = (anchor: int32, diagnostics: Diagnostic[], markdown: string): void => {
		const card = cardOf(diagnostics, markdown, columns, highlight);
		let i = -1;
		for (let k = 0; k < (frame.length as int32) && i < 0; k++) {
			if (frame[k].holds(anchor)) { i = k; }
		}
		if (card.rows.length == 0 || i < 0) {
			if (carded()) { setCarded(false); }
			return;
		}
		const cell = Math.max(0, cellIn(doc, frame[i], anchor) - view.left);
		const x = gutterWidth(doc.lineCount()) * grid.cellWidth + cell * grid.cellWidth;
		setCardBox(placed(card, x, i * grid.rowHeight, grid.rowHeight, grid.cellWidth, areaWidth));
		fill(cardRows, card.rows);
		setCarded(true);
	};

	const hoverAt = (offset: int32): void => {
		const diagnostics = session === null ? [] : (session as Session).diagnostics.at(doc, offset);
		hoverPoint = offset;
		if (diagnostics.length > 0) {
			cardOver = { from: diagnostics[0].from, to: diagnostics[0].to };
			showCard(offset, diagnostics, "");
		}
		if (session === null) { return; }
		const seq = hoverSeq;
		hoverAsked = (session as Session).hover(offset, (text: string, over: Span | null): void => {
			if (seq != hoverSeq) { return; }
			hoverAsked = -1;
			if (over !== null) { cardOver = over; }
			showCard(over === null ? offset : (over as Span).from, diagnostics, text);
		});
	};

	const offsetUnder = (e: NeonEvent): int32 => {
		if (frame.length == 0 || grid.cellWidth <= 0) { return -1; }
		const i = Math.floor(Math.max(0, e.locationY) / grid.rowHeight) as int32;
		const x = e.locationX - gutterWidth(doc.lineCount()) * grid.cellWidth;
		if (i >= (frame.length as int32) || x < 0) { return -1; }
		const r = frame[i];
		const at = doc.offsetAtCell(r.from, r.to, r.cell, view.left + (Math.floor(x / grid.cellWidth) as int32));
		return at >= r.to ? -1 : at;
	};

	const overCard = (e: NeonEvent): boolean => {
		const b = cardBox();
		return carded() && e.locationX >= b.x && e.locationX < b.x + b.width && e.locationY >= b.y && e.locationY < b.y + b.height;
	};

	const hovered = (e: NeonEvent): void => {
		if (overCard(e)) { return; }
		const at = offsetUnder(e);
		if (cardOver !== null && at >= (cardOver as Span).from && at < (cardOver as Span).to) { return; }
		if (at >= 0 && at == hoverPoint) { return; }
		hideCard();
		if (at < 0) { return; }
		hoverPoint = at;
		hoverTimer = setTimeout((): void => {
			hoverTimer = -1;
			hoverAt(at);
		}, HOVER_DELAY_MS);
	};

	const keptRow = (head: int32): int32 => {
		for (let k = 0; k < (frame.length as int32); k++) {
			if (frame[k].holds(head)) { return k; }
		}
		return -1;
	};

	const jumped = (target: Target, row: int32): void => {
		const here = target.here as Span;
		const oneLine = doc.lineOf(here.from) == doc.lineOf(here.to);
		editor.select({ ranges: [oneLine ? span(here.from, here.to) : span(here.from, here.from)], primary: 0 });
		if (row >= 0) { view = { ...view, line: Math.max(0, doc.lineOf(here.from) - row), sub: 0 }; }
		reveal();
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
			if (saved && session !== null) { (session as Session).saved(); }
			return refusal;
		},
		findBar: finder.open,
		findAgain: finder.again,
		hover: (): void => {
			const head = editor.selections.primaryRange().head;
			after = (): void => { hoverAt(head); };
		},
		goToDefinition: (): void => {
			if (session === null) {
				notice = "no language server for this file";
				return;
			}
			const head = editor.selections.primaryRange().head;
			const row = keptRow(head);
			const asked = (session as Session).definition(head, (found: Target[]): void => {
				if (found.length == 0) {
					notice = "no definition found";
				} else if (found[0].here !== null) {
					jumped(found[0], row);
					return;
				} else {
					const path = filePath(found[0].uri);
					notice = `definition in ${path === null ? found[0].uri : path as string}:${found[0].range.start.line + 1}`;
				}
				paint();
			});
			if (asked < 0) { notice = (session as Session).ready() ? "the language server has no definitions" : "the language server is not ready"; }
		},
		goToDiagnostic: (forward: boolean): void => {
			const start = editor.selections.primaryRange().start();
			const next = session === null ? null : (session as Session).diagnostics.next(doc, start, forward, active);
			if (next === null) {
				notice = "no diagnostics";
				return;
			}
			const d = next as Diagnostic;
			active = d;
			editor.select(single(d.from));
			after = (): void => {
				cardOver = { from: d.from, to: d.to };
				hoverPoint = d.from;
				showCard(d.from, [d], "");
			};
		},
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
		areaWidth = e.width;
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
		if (after !== null) {
			const then = after as () => void;
			after = null;
			then();
		}
	};

	const typed = (e: NeonEvent): void => {
		if (e.isComposing) { return; }
		hideCard();
		notice = null;
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
		hideCard();
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
		if (!e.pressed) {
			hovered(e);
			return;
		}
		if (gesture === null) { return; }
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
		if (moved) {
			hideCard();
			paint();
		}
	};

	if (session !== null) {
		(session as Session).watch((): void => {
			if (grid.cellWidth > 0) { paint(); }
		});
	}

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
			<HoverCard
				shown={carded()}
				box={cardBox()}
				rows={cardRows}
				cellWidth={drawn().cellWidth}
				rowHeight={drawn().rowHeight}
			/>
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
