import { NeonNode } from "../../../neon/src/render/node";
import { NeonEvent } from "../../../neon/src/render/event";
import { Accessor, createSignal } from "../../../neon/src/core/signal";
import { List, createList } from "../../../neon/src/core/list";
import { onSettled } from "../../../neon/src/core/effect";
import { Cleanup } from "../../../neon/src/core/types";
import { ForKeyedBy, ForList, Show } from "../../../neon/src/macros/ui/flow";
import { TextInputHandle, View, ViewHandle, Void } from "../../../neon/src/components/primitives";
import { Document } from "../model/document";
import { Editor } from "../model/editor";
import {
	Language,
	blockCommentOf,
	docCommentOf,
	endsWithNewlineOnSave,
	languageOf,
	lineCommentOf,
	trimsOnSave,
} from "../model/language";
import { guessIndent } from "../model/indent";
import { EditorConfigFile, editorConfigFor, indentFor } from "../model/editorconfig";
import { Clip } from "../model/commands";
import { MenuMove } from "../model/completer";
import { Tabs } from "../model/tabs";
import { QuickOpen } from "../model/quickOpen";
import { Switcher, SWITCHER_DELAY_MS } from "../model/switcher";
import { PaneHandle, Workspace } from "../model/workspace";
import { single } from "../model/selection";
import { KeyPress, chordOf } from "../input/keymap";
import { TabEntry, TabHit } from "../view/tabStrip";
import { Syntax, covers } from "../syntax/syntax";
import { Link, Session } from "../lsp/session";
import { Connection } from "../lsp/connection";
import { Away, editsIn } from "../lsp/server";
import { acceptLater } from "../model/completion";
import { offsetOf } from "../lsp/position";
import { BACKGROUND, MUTED, PADDING, PANEL, SELECTION } from "./theme";
import { EditorPane, measuredGrid } from "./components/features/editor/editorPane";
import { Strip, TabBar, hitIn, stripOf, tabRow } from "./components/features/tabs/tabBar";
import { Box, Overlay } from "./components/ui/overlay";
import { PICKER_PADDING, PICKER_ROWS, Picker } from "./components/ui/picker";
import { LineRow, Row } from "./components/content/lineRow";
import { quickOpenColumns, quickOpenRows, switcherRows } from "./components/features/quickOpen/quickOpenPicker";
import { scrolledTop } from "./components/features/completion/completionMenu";

const HIGHLIGHT_LIMIT: int32 = 512 * 1024;
const CLOSED_KEPT: int32 = 20;

export struct FileText {
	text: string;
	uri: string;
	error: string | null;
}

export interface Platform {
	clip: Clip;
	fail: (message: string) => void;
	read: (key: string) => FileText;
	store: (key: string, text: string) => string | null;
	files: () => string[];
	editorConfigs: (key: string) => EditorConfigFile[];
	keyOf: (shown: string) => string;
	keyOfUri: (uri: string) => string | null;
	shown: (key: string) => string;
	link: ((command: string) => Link | null) | null;
	rootUri: string | null;
	processId: int32 | null;
}

class Item {
	key: string;
	editor: Editor;
	syntax: Syntax | null;
	session: Session | null;
	serverNote: string;
	handle: PaneHandle | null = null;
	pendingJump: int32 = -1;

	constructor(key: string, editor: Editor, syntax: Syntax | null, session: Session | null, serverNote: string) {
		this.key = key;
		this.editor = editor;
		this.syntax = syntax;
		this.session = session;
		this.serverNote = serverNote;
	}
}

struct Spot {
	key: string;
	at: int32;
}

function fill<T>(list: List<T>, items: T[]): void {
	while (list.length() > items.length) { list.remove(list.length() - 1); }
	for (let i = 0; i < items.length; i++) {
		if (i < list.length()) { list.set(i, items[i]); } else { list.push(items[i]); }
	}
}

const NO_BOX: Box = { x: 0, y: 0, width: 0, height: 0, color: "" };

export function App(platform: Platform, first: string | null): NeonNode {
	const tabs = new Tabs();
	const items = new Map<string, Item>();
	const connections = new Map<string, Connection>();
	const closed: Spot[] = [];
	const backSpots: Spot[] = [];
	const forwardSpots: Spot[] = [];
	const switcher = new Switcher();
	let switchKeys: string[] = [];
	let closeArmed: string | null = null;
	let closeArmedVersion = -1;
	let frame: ViewHandle | null = null;
	let cellWidth = 0.0;
	let rowHeight = 0.0;
	let width = 0.0;
	let height = 0.0;
	let strip: Strip = { cells: [], left: 0 };
	let empty: ViewHandle | null = null;
	let elsewhere = (files: Away[]): string | null => "nothing opens files yet";

	const sessionFor = (key: string, doc: Document, uri: string): [Session | null, string] => {
		const language = languageOf(key);
		if (language === null || platform.link === null) { return [null, ""]; }
		const { id, server } = language as Language;
		let connection = connections.get(server);
		if (connection === undefined) {
			const link = (platform.link as (command: string) => Link | null)(server);
			if (link === null) { return [null, `cannot start ${server}`]; }
			connection = new Connection(link as Link, server, platform.rootUri, platform.processId);
			(connection as Connection).editsElsewhere((files: Away[]): string | null => elsewhere(files));
			connections.set(server, connection as Connection);
		}
		return [(connection as Connection).open(doc, uri, id), ""];
	};

	const load = (key: string, activate: boolean): string | null => {
		if (items.has(key)) {
			if (activate) { tabs.open(key); }
			return null;
		}
		const file = platform.read(key);
		if (file.error !== null) { return file.error as string; }
		const editor = new Editor(new Document(file.text));
		editor.lineComment = lineCommentOf(key);
		editor.blockComment = blockCommentOf(key);
		editor.docComment = docCommentOf(key);
		const settings = editorConfigFor(platform.editorConfigs(key), key);
		editor.indent = indentFor(settings, guessIndent(editor.doc));
		editor.trimOnSave = settings.trimTrailingWhitespace ?? trimsOnSave(key);
		editor.finalNewlineOnSave = settings.insertFinalNewline ?? endsWithNewlineOnSave(key);
		const syntax = covers(key) && editor.doc.length() <= HIGHLIGHT_LIMIT ? new Syntax() : null;
		const [session, note] = sessionFor(key, editor.doc, file.uri);
		items.set(key, new Item(key, editor, syntax, session, note));
		if (activate) { tabs.open(key); } else { const _added = tabs.add(key); }
		return null;
	};

	if (first !== null) {
		const failed = load(first as string, true);
		if (failed !== null) { platform.fail(failed as string); }
	}

	const [keys, setKeys] = createSignal<string[]>(tabs.keys());
	const [active, setActive] = createSignal<string>(tabs.active() === null ? "" : tabs.active() as string);
	const [tabLine, setTabLine] = createSignal<Row>({ spans: [] });
	const [drawnCell, setDrawnCell] = createSignal<float64>(0);
	const [drawnRow, setDrawnRow] = createSignal<float64>(0);
	const [opening, setOpening] = createSignal<boolean>(false);
	const [openQuery, setOpenQuery] = createSignal<string>("");
	const [openBox, setOpenBox] = createSignal<Box>(NO_BOX);
	const [openPick, setOpenPick] = createSignal<Box>(NO_BOX);
	const openLines: List<Row> = createList<Row>([]);
	let openTop = 0;
	const [switching, setSwitching] = createSignal<boolean>(false);
	const [switchBox, setSwitchBox] = createSignal<Box>(NO_BOX);
	const [switchPick, setSwitchPick] = createSignal<Box>(NO_BOX);
	const switchLines: List<Row> = createList<Row>([]);
	let placeOpen: () => void = (): void => {};
	const quickOpen = new QuickOpen((): void => { placeOpen(); });

	const activeItem = (): Item | null => {
		const key = tabs.active();
		if (key === null) { return null; }
		const found = items.get(key as string);
		return found === undefined ? null : found as Item;
	};

	const focusActive = (): void => {
		const item = activeItem();
		if (item === null) {
			if (empty !== null) { (empty as ViewHandle).focus(); }
		} else if ((item as Item).handle !== null) {
			((item as Item).handle as PaneHandle).focus();
		}
	};

	const tell = (message: string): void => {
		const item = activeItem();
		if (item !== null && (item as Item).handle !== null) { ((item as Item).handle as PaneHandle).tell(message); }
	};

	const paintTabs = (): void => {
		const entries: TabEntry[] = tabs.keys().map((k: string): TabEntry => {
			const item = items.get(k);
			return { path: platform.shown(k), dirty: item !== undefined && (item as Item).editor.isDirty() };
		});
		const columns = cellWidth <= 0 ? 0 : Math.floor(width / cellWidth) as int32;
		strip = stripOf(entries, tabs.activeIndex(), strip.left, columns);
		setTabLine(tabRow(strip, entries, tabs.activeIndex(), columns));
	};

	const shownTabs = (): void => {
		setKeys(tabs.keys());
		setActive(tabs.active() === null ? "" : tabs.active() as string);
		paintTabs();
		focusActive();
	};

	const open = (key: string): string | null => {
		const failed = load(key, true);
		if (failed === null) { shownTabs(); }
		return failed;
	};

	elsewhere = (files: Away[]): string | null => {
		const keys: string[] = [];
		for (const f of files) {
			const key = platform.keyOfUri(f.uri);
			if (key === null) { return `cannot open ${f.uri}`; }
			const failed = load(key as string, false);
			if (failed !== null) { return failed; }
			keys.push(key as string);
		}
		let skipped = 0;
		for (let i = 0; i < (files.length as int32); i++) {
			const editor = (items.get(keys[i]) as Item).editor;
			skipped += acceptLater(editor, editsIn(editor.doc, files[i]), editor.doc.version(), "");
		}
		shownTabs();
		if (skipped > 0) { tell(`left out ${skipped} edit${skipped == 1 ? "" : "s"} in other files that overlap another`); }
		return null;
	};

	const jumpTo = (key: string, at: int32): void => {
		const item = items.get(key);
		if (item === undefined) { return; }
		const it = item as Item;
		const inside = Math.min(at, it.editor.doc.length());
		if (it.handle !== null) {
			(it.handle as PaneHandle).jumpTo(inside);
		} else {
			it.editor.select(single(inside));
			it.pendingJump = inside;
		}
	};

	const here = (): Spot | null => {
		const item = activeItem();
		if (item === null || (item as Item).handle === null) { return null; }
		return { key: (item as Item).key, at: ((item as Item).handle as PaneHandle).head() };
	};

	const goTo = (key: string): string | null => {
		const from = here();
		const failed = open(key);
		if (failed !== null) { return failed; }
		if (from !== null && (from as Spot).key != key) {
			backSpots.push(from as Spot);
			forwardSpots.length = 0;
		}
		return null;
	};

	const close = (key: string): void => {
		const item = items.get(key);
		if (item === undefined) { return; }
		const it = item as Item;
		if (it.editor.isDirty() && !(closeArmed == key && closeArmedVersion == it.editor.doc.version())) {
			closeArmed = key;
			closeArmedVersion = it.editor.doc.version();
			tell(`${platform.shown(key)} has unsaved changes: ctrl+s saves them, closing again drops them`);
			return;
		}
		closeArmed = null;
		if (it.session !== null) { (it.session as Session).close(); }
		items.delete(key);
		closed.push({ key, at: it.editor.selections.primaryRange().head });
		if (closed.length > CLOSED_KEPT) { closed.shift(); }
		tabs.close(key);
		shownTabs();
	};

	const navigate = (back: boolean): void => {
		const from = back ? backSpots : forwardSpots;
		const to = back ? forwardSpots : backSpots;
		while (from.length > 0) {
			const spot = from.pop() as Spot;
			const now = here();
			if (open(spot.key) !== null) { continue; }
			if (now !== null) { to.push(now as Spot); }
			jumpTo(spot.key, spot.at);
			return;
		}
	};

	const placeSwitcher = (): void => {
		if (!switcher.shown(performance.now()) || cellWidth <= 0) {
			if (switching()) { setSwitching(false); }
			return;
		}
		const [rows, columns] = switcherRows(switchKeys.map((k: string): string => platform.shown(k)), PICKER_ROWS);
		fill(switchLines, rows);
		const boxWidth = columns * cellWidth + 2 * PICKER_PADDING;
		setSwitchPick({ x: 0, y: switcher.selected * rowHeight, width: columns * cellWidth, height: rowHeight, color: SELECTION });
		setSwitchBox({ x: Math.max(0, (width - boxWidth) / 2), y: rowHeight, width: boxWidth, height: rows.length * rowHeight, color: PANEL });
		if (!switching()) { setSwitching(true); }
	};

	placeOpen = (): void => {
		if (!quickOpen.showing()) {
			if (opening()) {
				setOpening(false);
				setOpenQuery("");
			}
			return;
		}
		if (cellWidth <= 0) { return; }
		const total = quickOpen.rows().length as int32;
		const columns = quickOpenColumns(width, cellWidth, PICKER_PADDING);
		const count = Math.max(1, Math.min(PICKER_ROWS, (Math.floor(height / rowHeight) as int32) - 4));
		openTop = scrolledTop(openTop, quickOpen.selected, count, total);
		fill(openLines, quickOpenRows(quickOpen, openTop, count, columns));
		const boxWidth = columns * cellWidth + 2 * PICKER_PADDING;
		setOpenPick({
			x: 0,
			y: (quickOpen.selected - openTop) * rowHeight,
			width: columns * cellWidth,
			height: total == 0 ? 0 : rowHeight,
			color: SELECTION,
		});
		setOpenBox({ x: Math.max(0, (width - boxWidth) / 2), y: rowHeight, width: boxWidth, height: Math.min(total, count) * rowHeight, color: PANEL });
		if (!opening()) { setOpening(true); }
	};

	const showQuickOpen = (): void => {
		quickOpen.files(platform.files());
		const current = tabs.active();
		quickOpen.history(tabs.recent().map((k: string): string => platform.shown(k)), current === null ? null : platform.shown(current as string));
		quickOpen.query("");
		quickOpen.show();
	};

	const hideQuickOpen = (): void => {
		quickOpen.hide();
		focusActive();
	};

	const confirmQuickOpen = (): void => {
		const chosen = quickOpen.chosen();
		const line = quickOpen.line();
		const column = quickOpen.column();
		hideQuickOpen();
		if (chosen === null) { return; }
		const key = platform.keyOf(chosen as string);
		const failed = goTo(key);
		if (failed !== null) {
			tell(failed as string);
			return;
		}
		if (line === null) { return; }
		const doc = (items.get(key) as Item).editor.doc;
		const l = Math.max(0, Math.min((line as int32) - 1, doc.lineCount() - 1));
		const c = column === null ? 0 : Math.max(0, (column as int32) - 1);
		jumpTo(key, Math.min(doc.lineStart(l) + c, doc.lineEnd(l)));
	};

	const workspace: Workspace = {
		quickOpen: showQuickOpen,
		openAt: (uri: string, line: int32, character: int32): string | null => {
			const key = platform.keyOfUri(uri);
			if (key === null) { return `cannot open ${uri}`; }
			const failed = goTo(key as string);
			if (failed !== null) { return failed; }
			jumpTo(key as string, offsetOf((items.get(key as string) as Item).editor.doc, { line, character }));
			return null;
		},
		closeTab: (): void => {
			const key = tabs.active();
			if (key !== null) { close(key as string); }
		},
		activateTab: (index: int32): void => {
			const count = tabs.keys().length as int32;
			if (count == 0) { return; }
			tabs.activate(index < 0 || index >= count ? count - 1 : index);
			shownTabs();
		},
		stepTab: (forward: boolean): void => {
			if (forward) { tabs.next(); } else { tabs.previous(); }
			shownTabs();
		},
		switchTabs: (last: boolean): void => {
			if (switcher.holding()) {
				switcher.move(!last);
			} else {
				switchKeys = tabs.recent();
				switcher.open(switchKeys.length as int32, last, performance.now());
				setTimeout((): void => { placeSwitcher(); }, SWITCHER_DELAY_MS + 20);
			}
			placeSwitcher();
		},
		keyUp: (ctrl: boolean): void => {
			if (ctrl || !switcher.holding()) { return; }
			const picked = switcher.released();
			placeSwitcher();
			if (picked === null || (picked as int32) >= switchKeys.length) { return; }
			const failed = open(switchKeys[picked as int32]);
			if (failed !== null) { tell(failed as string); }
		},
		reopenClosed: (): void => {
			while (closed.length > 0) {
				const spot = closed.pop() as Spot;
				if (open(spot.key) === null) {
					jumpTo(spot.key, spot.at);
					return;
				}
			}
		},
		navigate,
		changed: (): void => { paintTabs(); },
		measured: (cell: float64, row: float64): void => {
			if (cell == cellWidth && row == rowHeight) { return; }
			cellWidth = cell;
			rowHeight = row;
			setDrawnCell(cell);
			setDrawnRow(row);
			paintTabs();
		},
	};

	const emptyKey = (e: NeonEvent): void => {
		const press: KeyPress = { key: e.key, ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey, meta: e.metaKey };
		match (chordOf(press)) {
			"ctrl+p" | "ctrl+e" => { showQuickOpen(); }
			"ctrl+shift+t" => { workspace.reopenClosed(); }
			_ => {}
		}
	};

	return <Void style={{ backgroundColor: BACKGROUND, padding: PADDING }}>
		<View
			style={{ flexGrow: 1, flexShrink: 1, flexBasis: 0 }}
			ref={(handle: ViewHandle): void => { frame = handle; }}
			onLayout={(e: NeonEvent): void => {
				width = e.width;
				height = e.height;
				if (cellWidth == 0 && frame !== null) {
					const grid = measuredGrid(frame as ViewHandle);
					if (grid.cellWidth > 0 && grid.rowHeight > 0) { workspace.measured(grid.cellWidth, grid.rowHeight); }
				}
				paintTabs();
				placeOpen();
			}}
		>
			<TabBar
				row={tabLine()}
				cellWidth={drawnCell()}
				rowHeight={drawnRow()}
				hit={(column: int32): TabHit | null => hitIn(strip, column)}
				activate={(index: int32): void => { workspace.activateTab(index); }}
				close={(index: int32): void => {
					const all = tabs.keys();
					if (index >= 0 && index < all.length) { close(all[index]); }
				}}
			/>
			{ForKeyedBy<string, string>({
				each: keys,
				keyed: (k: string): string => k,
				children: (k: Accessor<string>): NeonNode => {
					const item = items.get(k()) as Item;
					return <View style={{ flexGrow: 1, flexShrink: 1, flexBasis: 0, display: active() == item.key ? "flex" : "none" }}>
						<EditorPane
							editor={item.editor}
							path={platform.shown(item.key)}
							syntax={item.syntax}
							clip={platform.clip}
							save={(text: string): string | null => platform.store(item.key, text)}
							fail={platform.fail}
							session={item.session}
							serverNote={item.serverNote}
							workspace={workspace}
							handle={(h: PaneHandle): void => {
								item.handle = h;
								if (item.pendingJump >= 0) {
									h.jumpTo(item.pendingJump);
									item.pendingJump = -1;
								}
							}}
							shown={(): boolean => active() == item.key}
						/>
					</View>;
				},
			})}
			<Show when={keys().length == 0}>
				<View
					style={{ flexGrow: 1, flexShrink: 1, flexBasis: 0, justifyContent: "center", alignItems: "center" }}
					focusable
					ref={(handle: ViewHandle): void => {
						empty = handle;
						onSettled((): Cleanup | null => {
							handle.focus();
							return (): void => { empty = null; };
						});
					}}
					onKeyDown={emptyKey}
				>
					<LineRow
						row={{ spans: [{ text: "ctrl+p opens a file · ctrl+shift+t reopens the last one closed", style: { color: MUTED } }] }}
						cellWidth={drawnCell()}
						rowHeight={drawnRow()}
					/>
				</View>
			</Show>
			<Picker
				placeholder="file"
				shown={opening()}
				box={openBox()}
				selected={openPick()}
				rows={openLines}
				query={openQuery()}
				cellWidth={drawnCell()}
				rowHeight={drawnRow()}
				attach={(input: TextInputHandle): void => { input.focus(); }}
				changed={(text: string): void => {
					setOpenQuery(text);
					quickOpen.query(text);
				}}
				moved={(m: MenuMove): void => { quickOpen.move(m); }}
				confirmed={confirmQuickOpen}
				cancelled={hideQuickOpen}
			/>
			<Show when={switching()}>
				<View
					style={{
						position: "absolute",
						left: switchBox().x,
						top: switchBox().y,
						width: switchBox().width,
						padding: PICKER_PADDING,
						backgroundColor: PANEL,
					}}>
					<View style={{ height: switchBox().height, overflow: "hidden" }}>
						<Overlay box={switchPick()} />
						{ForList<Row>({
							each: switchLines,
							children: (r: Accessor<Row>): NeonNode => <LineRow row={r()} cellWidth={drawnCell()} rowHeight={drawnRow()} />,
						})}
					</View>
				</View>
			</Show>
		</View>
	</Void>;
}
