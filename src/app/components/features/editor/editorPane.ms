import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { Accessor, createSignal } from "../../../../../../neon/src/core/signal";
import { List, createList } from "../../../../../../neon/src/core/list";
import { ForList, Show } from "../../../../../../neon/src/macros/ui/flow";
import { PixelRatio } from "../../../../../../neon/src/api/pixelRatio";
import { TextInputHandle, TextSelection, View, ViewHandle } from "../../../../../../neon/src/components/primitives";
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
import { Completer, MenuMove, Provider } from "../../../../model/completer";
import { Completion, acceptLater, queryAt } from "../../../../model/completion";
import { SignatureAsk, SignatureHelp, SignatureHelper, SignatureProvider } from "../../../../model/signatures";
import { Formatter } from "../../../../model/format";
import { Occurrence, Occurrences } from "../../../../model/occurrences";
import { Renamer, Renaming } from "../../../../model/rename";
import { Place, References } from "../../../../model/references";
import { CodeAction, CodeActions } from "../../../../model/actions";
import { Inlay, InlayHints } from "../../../../model/inlays";
import { Outline, OutlineItem } from "../../../../model/outline";
import { NavHistory, Spot } from "../../../../model/history";
import { Expander } from "../../../../model/expand";
import { KeyPress, Outcome, completionKeymap, defaultKeymap, listKeymap, signatureKeymap } from "../../../../input/keymap";
import { Viewport, centered, dragScrollRows } from "../../../../view/viewport";
import { VisualRow, cellIn, offsetIn, rowCells, rowIndexOf, rowsOf, shownCellIn } from "../../../../view/wrap";
import { Syntax, covers } from "../../../../syntax/syntax";
import { Bias, Document, Edit } from "../../../../model/document";
import { Tone } from "../../../../view/tone";
import { Diagnostic } from "../../../../model/diagnostics";
import { offsetAtCell } from "../../../../model/motion";
import { Session } from "../../../../lsp/session";
import { Span, Target } from "../../../../lsp/server";
import { filePath } from "../../../../lsp/uri";
import { CARET, FONT_SIZE, MUTED, PANEL, SELECTION } from "../../../theme";
import { caretPlace, goToHelp, statusLine } from "../../../../view/status";
import { Box, Overlay } from "../../ui/overlay";
import { LineRow, Row } from "../../content/lineRow";
import { Preedit } from "../../content/preedit";
import { FindBar } from "../find/findBar";
import { createFinder } from "../find/finder";
import { GoToBar } from "../goto/goToBar";
import { RenameField } from "../rename/renameField";
import { referenceColumns, referenceRows } from "../references/referenceList";
import { actionColumns, actionRows } from "../actions/actionList";
import { OUTLINE_PADDING, OUTLINE_ROWS, OutlinePicker, outlineColumns, outlineRows } from "../outline/outlinePicker";
import { HoverCard, cardOf, cardSize, placed } from "../hover/hoverCard";
import { CompletionMenu, MENU_BORDER, MENU_ROWS, menuColumns, menuPlaced, menuRows, scrolledTop } from "../completion/completionMenu";
import { signatureCard, signaturePlaced } from "../signature/signatureCard";
import { createBlink } from "./blink";
import { Grid, framed, gutterWidth, painted } from "./paint";

const PROBE = "MMMMMMMMMM";
const MULTI_CLICK_MS: float64 = 400;
const HOVER_DELAY_MS: float64 = 300;
const METASCRIPT = "metascript";
const ASIDE_GAP: float64 = 4;
const ASIDE_MIN_COLUMNS: int32 = 30;
const ASIDE_MAX_COLUMNS: int32 = 60;
const RENAME_COLUMNS: int32 = 30;

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
	let frameHints: Inlay[] = [];
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
	const [renamed, setRenamed] = createSignal<boolean>(false);
	const [renameBox, setRenameBox] = createSignal<Box>({ x: 0, y: 0, width: 0, height: 0, color: "" });
	const [renameName, setRenameName] = createSignal<string>("");
	const [renameSelection, setRenameSelection] = createSignal<TextSelection>({ start: 0, end: 0 });
	let renameText = "";
	let placeRename: () => void = (): void => {};
	let renameChanged: () => void = (): void => {};
	const listKeys = listKeymap();
	const [listed, setListed] = createSignal<boolean>(false);
	const [listBox, setListBox] = createSignal<Box>({ x: 0, y: 0, width: 0, height: 0, color: "" });
	const [listPick, setListPick] = createSignal<Box>({ x: 0, y: 0, width: 0, height: 0, color: "" });
	const listLines: List<Row> = createList<Row>([]);
	let listTop = 0;
	let placeReferences: () => void = (): void => {};
	let referencesChanged: () => void = (): void => {};
	const [outlined, setOutlined] = createSignal<boolean>(false);
	const [outlineQuery, setOutlineQuery] = createSignal<string>("");
	const [outlineBox, setOutlineBox] = createSignal<Box>({ x: 0, y: 0, width: 0, height: 0, color: "" });
	const [outlinePick, setOutlinePick] = createSignal<Box>({ x: 0, y: 0, width: 0, height: 0, color: "" });
	const outlineLines: List<Row> = createList<Row>([]);
	let outlineTop = 0;
	let outlineFrom: Viewport | null = null;
	let outlineHead = -1;
	let placeOutline: () => void = (): void => {};
	let outlineChanged: () => void = (): void => {};
	let listing: () => boolean = (): boolean => false;
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
	const menuKeys = completionKeymap();
	const [menued, setMenued] = createSignal<boolean>(false);
	const [menuBox, setMenuBox] = createSignal<Box>({ x: 0, y: 0, width: 0, height: 0, color: "" });
	const [menuPick, setMenuPick] = createSignal<Box>({ x: 0, y: 0, width: 0, height: 0, color: "" });
	const menuLines: List<Row> = createList<Row>([]);
	let menuTop = 0;
	const [asided, setAsided] = createSignal<boolean>(false);
	const [asideBox, setAsideBox] = createSignal<Box>({ x: 0, y: 0, width: 0, height: 0, color: "" });
	const asideRows: List<Row> = createList<Row>([]);
	let menuChanged: () => void = (): void => {};
	const provider: Provider = {
		ask: (offset: int32, trigger: string | null, done: (items: Completion[], incomplete: boolean) => void): int32 =>
			session === null ? -1 : (session as Session).completion(offset, trigger, done),
		resolve: (item: Completion, done: (resolved: Completion) => void): boolean =>
			session !== null && (session as Session).resolveCompletion(item, done) >= 0,
		cancel: (id: int32): void => { if (session !== null) { (session as Session).cancel(id); } },
		triggers: (): string[] => session === null ? [] : (session as Session).completionTriggers(),
	};
	const completer = new Completer(editor, provider, (): void => { menuChanged(); });
	const signKeys = signatureKeymap(false);
	const signKeysSeveral = signatureKeymap(true);
	const [signed, setSigned] = createSignal<boolean>(false);
	const [signBox, setSignBox] = createSignal<Box>({ x: 0, y: 0, width: 0, height: 0, color: "" });
	const signRows: List<Row> = createList<Row>([]);
	let signChanged: () => void = (): void => {};
	const signatureProvider: SignatureProvider = {
		ask: (q: SignatureAsk, done: (help: SignatureHelp | null) => void): int32 =>
			session === null ? -1 : (session as Session).signatureHelp(q, done),
		cancel: (id: int32): void => { if (session !== null) { (session as Session).cancel(id); } },
		wait: (ms: int32, run: () => void): int32 => setTimeout(run, ms) as int32,
		stopWaiting: (timer: int32): void => { clearTimeout(timer); },
		busy: (): boolean => completer.shown(),
		triggers: (): string[] => session === null ? [] : (session as Session).signatureTriggers(),
	};
	const signer = new SignatureHelper(editor, signatureProvider, (): void => { signChanged(); });
	let occurrencesChanged: () => void = (): void => {};
	const occurrences = new Occurrences(editor, {
		ask: (offset: int32, done: (found: Occurrence[] | null) => void): int32 =>
			session === null ? -1 : (session as Session).documentHighlight(offset, done),
		cancel: (id: int32): void => { if (session !== null) { (session as Session).cancel(id); } },
		wait: (ms: int32, run: () => void): int32 => setTimeout(run, ms) as int32,
		stopWaiting: (timer: int32): void => { clearTimeout(timer); },
	}, (): void => { occurrencesChanged(); });
	const history = new NavHistory(doc);
	let seenAt = 0;
	let seenVersion = doc.version();
	let seenTop = 0;
	let jumping = false;
	const extension = props.path.lastIndexOf(".") < 0 ? "" : props.path.slice(props.path.lastIndexOf(".") + 1);
	let hintsChanged: () => void = (): void => {};
	const hints = new InlayHints(doc, {
		ask: (from: int32, to: int32, done: (found: Inlay[] | null) => void): int32 =>
			session === null ? -1 : (session as Session).inlayHints(from, to, done),
		cancel: (id: int32): void => { if (session !== null) { (session as Session).cancel(id); } },
		wait: (ms: int32, run: () => void): int32 => setTimeout(run, ms) as int32,
		stopWaiting: (timer: int32): void => { clearTimeout(timer); },
	}, (message: string): void => {
		notice = message;
		hintsChanged();
	}, (): void => { hintsChanged(); });
	const lineHints = (line: int32): Inlay[] => hints.within(doc.lineStart(line), doc.lineEnd(line));

	const wrapWidth = (): int32 => wrap ? view.cols : 0;
	const lineRowsOf = (line: int32): Vec<VisualRow> => rowsOf(doc, line, wrapWidth(), wrap ? lineHints(line) : []);
	const rowsIn = (line: int32): int32 => lineRowsOf(line).length as int32;

	const frameUp = (): void => {
		frame = framed(doc, view, wrapWidth(), lineHints);
		frameHints = frame.length == 0 ? [] : hints.within(frame[0].from, frame[frame.length - 1].to);
	};

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

	const placeAside = (menu: Box, above: boolean): void => {
		const item = completer.selectedItem();
		const text = item === null ? "" : (item as Completion).documentation;
		const right = areaWidth - menu.x - menu.width - ASIDE_GAP;
		const left = menu.x - ASIDE_GAP;
		const room = Math.floor(Math.max(right, left) / grid.cellWidth) as int32;
		if (text.trim().byteLength == 0 || room < ASIDE_MIN_COLUMNS) {
			if (asided()) { setAsided(false); }
			return;
		}
		const card = cardOf([], text, Math.min(room, ASIDE_MAX_COLUMNS), highlight);
		const [width, height] = cardSize(card, grid.rowHeight, grid.cellWidth);
		setAsideBox({
			x: right >= left ? menu.x + menu.width + ASIDE_GAP : menu.x - ASIDE_GAP - width,
			y: above ? Math.max(0, menu.y + menu.height - height) : menu.y,
			width,
			height,
			color: PANEL,
		});
		fill(asideRows, card.rows);
		setAsided(true);
	};

	const placeMenu = (): void => {
		let row = -1;
		const head = editor.selections.primaryRange().head;
		const query = queryAt(doc, head);
		const word = query === null ? head : head - ((query as string).byteLength as int32);
		for (let k = 0; k < (frame.length as int32) && row < 0 && completer.shown(); k++) {
			if (frame[k].holds(word)) { row = k; }
		}
		if (row < 0 || grid.cellWidth <= 0) {
			if (menued()) { setMenued(false); }
			if (asided()) { setAsided(false); }
			return;
		}
		const total = completer.choices.length as int32;
		const columns = menuColumns(completer.items, completer.choices);
		const cell = Math.max(0, cellIn(doc, frame[row], word, frameHints) - view.left);
		const x = (gutterWidth(doc.lineCount()) + cell) * grid.cellWidth;
		const place = menuPlaced(columns, Math.min(total, MENU_ROWS), x, row, view.rows, grid.rowHeight, grid.cellWidth, areaWidth, PANEL);
		menuTop = scrolledTop(menuTop, completer.selected, place.rows, total);
		fill(menuLines, menuRows(completer.items, completer.choices, menuTop, place.rows, columns));
		setMenuPick({
			x: 0,
			y: (completer.selected - menuTop) * grid.rowHeight,
			width: place.box.width - 2 * MENU_BORDER,
			height: grid.rowHeight,
			color: SELECTION,
		});
		setMenuBox(place.box);
		setMenued(true);
		placeAside(place.box, place.above);
	};

	const placeSignature = (): void => {
		const help = signer.help;
		const head = editor.selections.primaryRange().head;
		let row = -1;
		for (let k = 0; k < (frame.length as int32) && row < 0 && help !== null; k++) {
			if (frame[k].holds(head)) { row = k; }
		}
		if (row < 0 || grid.cellWidth <= 0) {
			if (signed()) { setSigned(false); }
			return;
		}
		const card = signatureCard(help as SignatureHelp, signer.current, extension, columns, view.rows, highlight);
		const cell = Math.max(0, cellIn(doc, frame[row], head, frameHints) - view.left);
		const x = (gutterWidth(doc.lineCount()) + cell) * grid.cellWidth;
		const menu = menued() ? menuBox() : null;
		setSignBox(signaturePlaced(card, x, row * grid.rowHeight, grid.rowHeight, grid.cellWidth, areaWidth, areaHeight, menu));
		fill(signRows, card.rows);
		setSigned(true);
	};

	const paint = (): void => {
		fit();
		if (!listing()) {
			const was = doc.offsetSince(seenVersion, seenAt, Bias.Left);
			const head = editor.selections.primaryRange().head;
			if (was !== null) { history.moved({ at: was as int32, top: seenTop }, head, jumping); }
			jumping = false;
			seenAt = head;
			seenVersion = doc.version();
			seenTop = view.line;
		}
		if (session !== null) { (session as Session).edited(); }
		frameUp();
		if (frame.length > 0) { hints.visible(frame[0].from, frame[frame.length - 1].to); }
		const shownOccurrences = frame.length == 0 ? [] : occurrences.within(frame[0].from, frame[frame.length - 1].to);
		const p = painted(doc, editor.selections, marked(), bracketed(), shownOccurrences, frame, view, syntax, visibleDiagnostics(), grid, frameHints);
		fill(rows, p.rows);
		fill(shades, p.shades);
		fill(carets, p.carets);
		if (p.primary !== null) { setCaret(p.primary); }
		blink.restart();
		placeMenu();
		placeSignature();
		placeRename();
		placeReferences();
		placeOutline();
		report();
	};

	const reveal = (): void => {
		fit();
		const head = editor.selections.primaryRange().head;
		const line = doc.lineOf(head);
		const lineRows = lineRowsOf(line);
		const k = rowIndexOf(lineRows, head);
		view = view.revealed(line, k, doc.lineCount(), rowsIn);
		if (!wrap) { view = view.revealedCell(cellIn(doc, lineRows[k], head, lineHints(line))); }
		paint();
	};

	const focus = (): void => {
		if (area !== null) { (area as ViewHandle).focus(); }
	};

	let hoverSeq = 0;
	let after: (() => void) | null = null;
	let scrolledOnly = false;

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
		const cell = Math.max(0, cellIn(doc, frame[i], anchor, frameHints) - view.left);
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
		const shown = shownCellIn(doc, r, view.left + (Math.floor(x / grid.cellWidth) as int32), frameHints);
		if (shown.hintAt >= 0) { return -1; }
		const at = doc.offsetAtCell(r.from, r.to, r.cell, shown.text);
		return at >= r.to ? -1 : at;
	};

	const inside = (b: Box, e: NeonEvent): boolean =>
		e.locationX >= b.x && e.locationX < b.x + b.width && e.locationY >= b.y && e.locationY < b.y + b.height;

	const overMenu = (e: NeonEvent): boolean => menued() && inside(menuBox(), e);

	const overCard = (e: NeonEvent): boolean => carded() && inside(cardBox(), e);

	const hovered = (e: NeonEvent): void => {
		if (overCard(e) || overMenu(e)) { return; }
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
		jumping = true;
		reveal();
	};

	menuChanged = (): void => {
		if (completer.shown()) { hideCard(); }
		if (grid.cellWidth > 0) { paint(); }
	};
	const formatter = new Formatter(editor, {
		format: (range: [int32, int32] | null, done: (edits: Edit[] | null, error: string | null) => void): int32 =>
			session === null ? -1 : (session as Session).format(range, (edits: Edit[] | null, error: string | null): void => {
				done(edits, error);
				paint();
			}),
		cancel: (id: int32): void => { if (session !== null) { (session as Session).cancel(id); } },
		wait: (ms: int32, run: () => void): int32 => setTimeout(run, ms) as int32,
		stopWaiting: (timer: int32): void => { clearTimeout(timer); },
	}, (message: string): void => {
		notice = message;
		paint();
	});
	const renamer = new Renamer(editor, {
		prepares: (): boolean => session !== null && (session as Session).prepares(),
		prepare: (offset: int32, done: (range: [int32, int32] | null, error: string | null) => void): int32 =>
			session === null ? -1 : (session as Session).prepareRename(offset, done),
		rename: (offset: int32, name: string, done: (edits: Edit[] | null, others: int32, error: string | null) => void): int32 =>
			session === null ? -1 : (session as Session).rename(offset, name, (edits: Edit[] | null, others: int32, error: string | null): void => {
				done(edits, others, error);
				occurrences.moved();
				paint();
			}),
		cancel: (id: int32): void => { if (session !== null) { (session as Session).cancel(id); } },
	}, (message: string): void => {
		notice = message;
		paint();
	}, (): void => { renameChanged(); });
	renameChanged = (): void => {
		const at = renamer.renaming();
		if (at === null) {
			if (renamed()) {
				setRenamed(false);
				focus();
			}
			return;
		}
		const r = at as Renaming;
		renameText = r.old;
		setRenameName(r.old);
		setRenameSelection({ start: r.old.byteSlice(0, r.selectFrom).length, end: r.old.byteSlice(0, r.selectTo).length });
		reveal();
		setRenamed(true);
	};
	const references = new References(editor, {
		ask: (offset: int32, done: (found: Place[] | null) => void): int32 =>
			session === null ? -1 : (session as Session).references(offset, done),
		cancel: (id: int32): void => { if (session !== null) { (session as Session).cancel(id); } },
	}, (message: string): void => {
		notice = message;
		paint();
	}, (): void => { referencesChanged(); });
	referencesChanged = (): void => {
		if (grid.cellWidth > 0) { reveal(); }
	};
	const actions = new CodeActions(editor, {
		ask: (from: int32, to: int32, done: (found: CodeAction[] | null) => void): int32 =>
			session === null ? -1 : (session as Session).codeActions(from, to, done),
		apply: (action: CodeAction, done: (edits: Edit[] | null, others: int32, error: string | null) => void): int32 =>
			session === null ? -1 : (session as Session).applyAction(action, done),
		cancel: (id: int32): void => { if (session !== null) { (session as Session).cancel(id); } },
	}, (message: string): void => {
		notice = message;
		paint();
	}, (): void => { referencesChanged(); });
	if (session !== null) {
		(session as Session).applying((edits: Edit[], others: int32): string | null => {
			if (others > 0) { return `the edit also changes ${others} other file${others == 1 ? "" : "s"}, and medic edits one file`; }
			const skipped = acceptLater(editor, edits, doc.version(), "");
			if (skipped > 0) { notice = `left out ${skipped} edit${skipped == 1 ? "" : "s"} from the language server that overlap another`; }
			reveal();
			return null;
		});
	}
	placeReferences = (): void => {
		const head = editor.selections.primaryRange().head;
		const shown = actions.shown() || references.shown();
		let row = -1;
		for (let k = 0; k < (frame.length as int32) && row < 0 && shown; k++) {
			if (frame[k].holds(head)) { row = k; }
		}
		if (row < 0 || grid.cellWidth <= 0) {
			if (listed()) { setListed(false); }
			return;
		}
		const places = references.places();
		const offered = actions.actions();
		const total = actions.shown() ? offered.length as int32 : places.length as int32;
		const selected = actions.shown() ? actions.selected : references.selected;
		const columns = actions.shown() ? actionColumns(offered) : referenceColumns(doc, places);
		const cell = actions.shown() ? Math.max(0, cellIn(doc, frame[row], head, frameHints) - view.left) : 0;
		const x = (gutterWidth(doc.lineCount()) + cell) * grid.cellWidth;
		const place = menuPlaced(columns, Math.min(total, MENU_ROWS), x, row, view.rows, grid.rowHeight, grid.cellWidth, areaWidth, PANEL);
		listTop = scrolledTop(listTop, selected, place.rows, total);
		fill(listLines, actions.shown() ? actionRows(offered, listTop, place.rows, columns) : referenceRows(doc, places, listTop, place.rows, columns));
		setListPick({
			x: 0,
			y: (selected - listTop) * grid.rowHeight,
			width: place.box.width - 2 * MENU_BORDER,
			height: grid.rowHeight,
			color: SELECTION,
		});
		setListBox(place.box);
		setListed(true);
	};
	const outline = new Outline(editor, {
		ask: (done: (found: OutlineItem[] | null) => void): int32 =>
			session === null ? -1 : (session as Session).documentSymbols(done),
		cancel: (id: int32): void => { if (session !== null) { (session as Session).cancel(id); } },
	}, (message: string): void => {
		notice = message;
		paint();
	}, (): void => { outlineChanged(); });
	listing = (): boolean => outline.shown() || references.shown();
	outlineChanged = (): void => {
		if (!outline.shown()) {
			if (outlined()) {
				outlineFrom = null;
				setOutlineQuery("");
				setOutlined(false);
			}
			paint();
			return;
		}
		const head = editor.selections.primaryRange().head;
		if (outlineFrom === null) {
			outlineFrom = view;
			outlineHead = head;
			outlineTop = 0;
		}
		view = head == outlineHead ? outlineFrom as Viewport : view.centered(doc.lineOf(head), doc.lineCount(), rowsIn);
		paint();
	};
	placeOutline = (): void => {
		if (!outline.shown() || grid.cellWidth <= 0) { return; }
		const total = outline.rows().length as int32;
		const columns = outlineColumns(outline);
		const count = Math.max(1, Math.min(OUTLINE_ROWS, view.rows - 3));
		outlineTop = scrolledTop(outlineTop, outline.selected, count, total);
		fill(outlineLines, outlineRows(outline, outlineTop, count, columns));
		const width = columns * grid.cellWidth + 2 * OUTLINE_PADDING;
		setOutlinePick({
			x: 0,
			y: (outline.selected - outlineTop) * grid.rowHeight,
			width: columns * grid.cellWidth,
			height: total == 0 ? 0 : grid.rowHeight,
			color: SELECTION,
		});
		setOutlineBox({ x: Math.max(0, (areaWidth - width) / 2), y: 0, width, height: Math.min(total, count) * grid.rowHeight, color: PANEL });
		if (!outlined()) { setOutlined(true); }
	};
	const outlineConfirmed = (): void => {
		outline.confirm();
		view = view.centered(doc.lineOf(editor.selections.primaryRange().head), doc.lineCount(), rowsIn);
		paint();
		focus();
	};
	const outlineCancelled = (): void => {
		if (outlineFrom !== null) { view = outlineFrom as Viewport; }
		outline.dismiss();
		focus();
	};
	placeRename = (): void => {
		const at = renamer.renaming();
		if (at === null || grid.cellWidth <= 0) { return; }
		const from = (at as Renaming).from;
		let row = -1;
		for (let k = 0; k < (frame.length as int32) && row < 0; k++) {
			if (frame[k].holds(from)) { row = k; }
		}
		if (row < 0) { return; }
		const cell = Math.max(0, cellIn(doc, frame[row], from, frameHints) - view.left);
		const width = Math.min(areaWidth, RENAME_COLUMNS * grid.cellWidth);
		const x = Math.max(0, Math.min((gutterWidth(doc.lineCount()) + cell) * grid.cellWidth, areaWidth - width));
		setRenameBox({ x, y: (row + 1) * grid.rowHeight, width, height: 0, color: "" });
	};
	occurrencesChanged = (): void => {
		if (grid.cellWidth > 0) { paint(); }
	};
	signChanged = (): void => {
		if (grid.cellWidth > 0) { paint(); }
	};
	hintsChanged = (): void => {
		if (grid.cellWidth > 0) { paint(); }
	};
	const menuCommands = new Set<string>(menuKeys.commands());
	menuCommands.add("showCompletions");
	const signatureCommands = new Set<string>(signKeysSeveral.commands());
	signatureCommands.add("showSignatureHelp");

	const cx: Context = {
		pageRows: (): int32 => Math.max(1, view.rows - 1),
		scrollRows: (rows: int32): void => {
			view = view.scrolledBy(rows, doc.lineCount(), rowsIn);
			scrolledOnly = true;
			hideCard();
			signer.dismiss();
		},
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
		showCompletions: (): void => { completer.update(null); },
		completionMenu: (move: MenuMove): void => { completer.move(move); },
		confirmCompletion: (replace: boolean | null): void => {
			const skipped = completer.confirm(replace);
			if (skipped === null) { return; }
			if ((skipped as int32) > 0) {
				notice = `left out ${skipped as int32} edit${skipped == 1 ? "" : "s"} the completion brought that overlap it`;
			}
			signer.invoke();
		},
		hideCompletions: (): void => { completer.hide(); },
		showSignatureHelp: (): void => { signer.invoke(); },
		cycleSignature: (forward: boolean): void => { signer.cycle(forward); },
		hideSignatureHelp: (): void => { signer.dismiss(); },
		format: (selections: boolean): void => { formatter.run(selections); },
		rename: (): void => { renamer.start(); },
		findReferences: (): void => {
			completer.hide();
			actions.close();
			references.find();
		},
		moveList: (move: MenuMove): void => {
			if (actions.shown()) { actions.move(move); }
			else { references.move(move); }
		},
		confirmList: (): void => {
			if (actions.shown()) { actions.confirm(); }
			else { references.confirm(); }
		},
		hideList: (): void => {
			actions.close();
			references.dismiss();
		},
		codeActions: (): void => {
			completer.hide();
			references.close();
			actions.toggle();
		},
		toggleInlayHints: (): void => { hints.toggle(); },
		outline: (): void => {
			completer.hide();
			references.close();
			actions.close();
			outline.open();
		},
		navigate: (back: boolean): void => {
			const here: Spot = { at: editor.selections.primaryRange().head, top: view.line };
			const to = back ? history.back(here) : history.onward(here);
			if (to === null) { return; }
			const s = to as Spot;
			editor.select(single(s.at));
			view = { ...view, line: Math.min(s.top, doc.lineCount() - 1), sub: 0 };
			seenAt = s.at;
			seenVersion = doc.version();
			reveal();
		},
		goToLine: (): void => {
			goingFrom = view;
			setGoingTo(true);
			paint();
		},
		expander: new Expander(syntax === null ? null : (syntax as Syntax).ancestors(doc)),
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
		if (!menuCommands.has(name) && !signatureCommands.has(name)) {
			completer.moved();
			signer.moved(null);
			occurrences.moved();
		}
		if (scrolledOnly) { paint(); } else { reveal(); }
		scrolledOnly = false;
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
		const key: KeyPress = { key: e.key, ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey, meta: e.metaKey };
		if ((actions.shown() || references.shown()) && keymap.pendingChords() == "") {
			const m = listKeys.feed(key);
			if (m.outcome == Outcome.Run) {
				run(m.command);
				return;
			}
			actions.close();
			references.close();
		}
		outline.close();
		if (completer.shown() && keymap.pendingChords() == "") {
			const m = menuKeys.feed(key);
			if (m.outcome == Outcome.Run) {
				run(m.command);
				return;
			}
		} else if (signer.shown() && keymap.pendingChords() == "") {
			const several = (signer.help as SignatureHelp).signatures.length > 1;
			const m = (several ? signKeysSeveral : signKeys).feed(key);
			if (m.outcome == Outcome.Run) {
				run(m.command);
				return;
			}
		}
		const r = keymap.feed(key);
		if (r.outcome == Outcome.Run) { run(r.command); }
		else if (r.outcome == Outcome.Unbound && printable(e.text)) {
			insertText(editor, e.text);
			reveal();
			completer.typed(e.text);
			signer.moved(e.text);
			occurrences.moved();
		}
	};

	const committed = (e: NeonEvent): void => {
		setPreedit("");
		if (e.text == "") { return; }
		insertText(editor, e.text);
		reveal();
		completer.typed(e.text);
		signer.moved(e.text);
		occurrences.moved();
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
		return offsetIn(doc, frame[Math.min(i, (frame.length as int32) - 1)], view.left + Math.max(0, cell), frameHints);
	};

	const pressed = (e: NeonEvent): void => {
		hideCard();
		if (renamed()) { renamer.cancel(); }
		references.close();
		outline.close();
		if (actions.shown() && listed() && e.button == 1 && inside(listBox(), e)) {
			actions.pick(listTop + (Math.floor((e.locationY - listBox().y - MENU_BORDER) / grid.rowHeight) as int32));
			return;
		}
		actions.close();
		if (grid.cellWidth <= 0 || e.button != 1) { return; }
		if (overMenu(e)) {
			completer.pick(menuTop + (Math.floor((e.locationY - menuBox().y - MENU_BORDER) / grid.rowHeight) as int32));
			run("confirmCompletion");
			return;
		}
		completer.hide();
		const offset = offsetAt(e);
		const now = Date.now();
		clicks = now - lastPress < MULTI_CLICK_MS && offset == lastOffset ? clicks % 3 + 1 : 1;
		lastPress = now;
		lastOffset = offset;
		gesture = press(editor, offset, clicks, e.shiftKey, e.altKey);
		signer.moved(null);
		occurrences.moved();
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
			frameUp();
		}
		drag(editor, gesture as Gesture, offsetAt(e));
		signer.moved(null);
		occurrences.moved();
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
		for (const r of frame) { most = Math.max(most, rowCells(doc, r, frameHints)); }
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
			signer.dismiss();
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
			<CompletionMenu
				shown={menued()}
				box={menuBox()}
				selected={menuPick()}
				rows={menuLines}
				cellWidth={drawn().cellWidth}
				rowHeight={drawn().rowHeight}
			/>
			<HoverCard
				shown={asided()}
				box={asideBox()}
				rows={asideRows}
				cellWidth={drawn().cellWidth}
				rowHeight={drawn().rowHeight}
			/>
			<CompletionMenu
				shown={listed()}
				box={listBox()}
				selected={listPick()}
				rows={listLines}
				cellWidth={drawn().cellWidth}
				rowHeight={drawn().rowHeight}
			/>
			<HoverCard
				shown={signed()}
				box={signBox()}
				rows={signRows}
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
		<OutlinePicker
			shown={outlined()}
			box={outlineBox()}
			selected={outlinePick()}
			rows={outlineLines}
			query={outlineQuery()}
			cellWidth={drawn().cellWidth}
			rowHeight={drawn().rowHeight}
			attach={(input: TextInputHandle): void => { input.focus(); }}
			changed={(text: string): void => {
				setOutlineQuery(text);
				outline.search(text);
			}}
			moved={(m: MenuMove): void => { outline.move(m); }}
			confirmed={outlineConfirmed}
			cancelled={outlineCancelled}
		/>
		<RenameField
			shown={renamed()}
			box={renameBox()}
			name={renameName()}
			selection={renameSelection()}
			changed={(text: string): void => {
				renameText = text;
				setRenameName(text);
			}}
			confirmed={(): void => { renamer.confirm(renameText); }}
			cancelled={(): void => { renamer.cancel(); }}
		/>
		<View style={{ height: drawn().rowHeight, backgroundColor: PANEL }}>
			<LineRow row={status()} cellWidth={drawn().cellWidth} rowHeight={drawn().rowHeight} />
		</View>
	</View>;
}
