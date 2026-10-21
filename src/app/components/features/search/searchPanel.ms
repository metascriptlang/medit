import { onSettled } from "../../../../../../neon/src/core/effect";
import { Cleanup } from "../../../../../../neon/src/core/types";
import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { Accessor, createSignal } from "../../../../../../neon/src/core/signal";
import { List, createList } from "../../../../../../neon/src/core/list";
import { ForList, Show } from "../../../../../../neon/src/macros/ui/flow";
import { Text, TextInputHandle, View } from "../../../../../../neon/src/components/primitives";
import { TextSpan } from "../../../../../../neon/src/render/hostTypes";
import { Style } from "../../../../../../neon/src/render/style";
import { Query } from "../../../../model/find";
import { Hit, ProjectResults, hitOfRow, located, rowCount, stepped } from "../../../../model/projectSearch";
import { FOREGROUND, MATCH, MUTED, PANEL, SELECTION } from "../../../theme";
import { Field } from "../../ui/field";
import { Box, Overlay } from "../../ui/overlay";
import { PICKER_GAP, PICKER_PADDING } from "../../ui/picker";
import { LineRow, Row } from "../../content/lineRow";
import { cellsOf, clipped, scrolledTop } from "../completion/completionMenu";

export const SEARCH_ROWS: int32 = 10;

export interface SearchHandle {
	show: () => void;
	step: (forward: boolean) => boolean;
}

function filled(spans: TextSpan[], used: int32, columns: int32): Row {
	if (used < columns) { spans.push({ text: " ".repeat(columns - used) }); }
	return { spans };
}

function pushed(spans: TextSpan[], text: string, style: Style, room: int32): int32 {
	const shown = clipped(text, room);
	if (shown.byteLength > 0) { spans.push({ text: shown, style }); }
	return cellsOf(shown);
}

export function fileHeaderRow(path: string, count: int32, columns: int32): Row {
	const spans: TextSpan[] = [];
	let used = pushed(spans, path, { color: FOREGROUND }, columns);
	used += pushed(spans, `  ${count}`, { color: MUTED }, columns - used);
	return filled(spans, used, columns);
}

export function hitRow(hit: Hit, columns: int32): Row {
	const spans: TextSpan[] = [];
	const text = hit.text.replaceAll("\t", " ");
	const from = Math.min(hit.from - hit.textFrom, text.byteLength as int32);
	const to = Math.min(hit.to - hit.textFrom, text.byteLength as int32);
	let used = pushed(spans, `  ${hit.line + 1}: `, { color: MUTED }, columns);
	used += pushed(spans, text.byteSlice(0, from), { color: FOREGROUND }, columns - used);
	used += pushed(spans, text.byteSlice(from, to), { color: FOREGROUND, backgroundColor: MATCH }, columns - used);
	used += pushed(spans, text.byteSlice(to, text.byteLength), { color: FOREGROUND }, columns - used);
	return filled(spans, used, columns);
}

export function searchRows(r: ProjectResults, shown: (key: string) => string, top: int32, count: int32, columns: int32): Row[] {
	const rows: Row[] = [];
	let row = 0;
	for (const f of r.files) {
		if (row >= top + count) { break; }
		const n = f.hits.length as int32;
		if (row + n >= top) {
			if (row >= top) { rows.push(fileHeaderRow(shown(f.key), n, columns)); }
			for (let i = Math.max(0, top - row - 1); i < n && (rows.length as int32) < count; i++) {
				rows.push(hitRow(f.hits[i], columns));
			}
		}
		row += 1 + n;
	}
	return rows;
}

export function searchNote(r: ProjectResults | null): string {
	if (r === null) { return "Enter searches the project"; }
	const found = r as ProjectResults;
	if (found.matches == 0) { return "no matches"; }
	const counted = `${found.matches} ${found.matches == 1 ? "match" : "matches"} in ${found.files.length} ${found.files.length == 1 ? "file" : "files"}`;
	return found.limitReached ? `${counted} · limit reached` : counted;
}

const NO_BOX: Box = { x: 0, y: 0, width: 0, height: 0, color: "" };

export function SearchPanel(props: {
	cellWidth: Accessor<float64>;
	rowHeight: Accessor<float64>;
	search: (q: Query) => ProjectResults;
	shown: (key: string) => string;
	open: (key: string, hit: Hit) => void;
	closed: () => void;
	handle: (h: SearchHandle) => void;
}): NeonNode {
	const [showing, setShowing] = createSignal<boolean>(false);
	const [query, setQuery] = createSignal<string>("");
	const [note, setNote] = createSignal<TextSpan[]>([]);
	const [picked, setPicked] = createSignal<Box>(NO_BOX);
	const lines: List<Row> = createList<Row>([]);
	let input: TextInputHandle | null = null;
	let width = 0.0;
	let caseSensitive = false;
	let wholeWord = false;
	let results: ProjectResults | null = null;
	let ran: Query | null = null;
	let selected = -1;
	let opened = false;
	let top = 0;

	const wanted = (): Query => ({ text: query(), caseSensitive, wholeWord });

	const columns = (): int32 => props.cellWidth() <= 0 ? 0 : Math.floor(width / props.cellWidth()) as int32;

	let paint: () => void = (): void => {};

	const run = (): void => {
		const q = wanted();
		if (q.text.byteLength == 0) { return; }
		results = props.search(q);
		ran = q;
		selected = (results as ProjectResults).matches > 0 ? 0 : -1;
		opened = false;
		top = 0;
		paint();
	};

	const rerun = (): void => {
		if (results === null || query().byteLength == 0) { paint(); } else { run(); }
	};

	const openSelected = (): void => {
		if (results === null || selected < 0) { return; }
		const at = located(results as ProjectResults, selected);
		opened = true;
		props.open(at.key, at.hit);
	};

	const pressable = (row: Row, at: int32): Row => ({
		spans: row.spans.map((span: TextSpan): TextSpan => ({
			...span,
			onPress: (e: NeonEvent): void => {
				if (results === null) { return; }
				selected = hitOfRow(results as ProjectResults, at);
				paint();
				openSelected();
			},
		})),
	});

	const toggle = (label: string, on: boolean, flip: () => void): TextSpan => ({
		text: label,
		style: { color: on ? FOREGROUND : MUTED },
		onPress: (e: NeonEvent): void => {
			flip();
			rerun();
		},
	});

	paint = (): void => {
		setNote([
			toggle("Aa", caseSensitive, (): void => { caseSensitive = !caseSensitive; }),
			{ text: " " },
			toggle("Word", wholeWord, (): void => { wholeWord = !wholeWord; }),
			{ text: `   ${searchNote(results)}`, style: { color: MUTED } },
		]);
		const lineCount = columns();
		if (results === null || lineCount <= 0) {
			while (lines.length() > 0) { lines.remove(lines.length() - 1); }
			setPicked(NO_BOX);
			return;
		}
		const found = results as ProjectResults;
		const at = selected < 0 ? -1 : located(found, selected).row;
		top = scrolledTop(top, Math.max(0, at), SEARCH_ROWS, rowCount(found));
		const rows = searchRows(found, props.shown, top, SEARCH_ROWS, lineCount);
		while (lines.length() > rows.length) { lines.remove(lines.length() - 1); }
		for (let i = 0; i < rows.length; i++) {
			const row = pressable(rows[i], top + i);
			if (i < lines.length()) { lines.set(i, row); } else { lines.push(row); }
		}
		setPicked(at < 0 ? NO_BOX : {
			x: 0,
			y: (at - top) * props.rowHeight(),
			width: lineCount * props.cellWidth(),
			height: props.rowHeight(),
			color: SELECTION,
		});
	};

	const step = (forward: boolean): boolean => {
		if (!showing() || results === null || (results as ProjectResults).matches == 0) { return false; }
		if (opened || !forward) { selected = stepped(results as ProjectResults, selected, forward); }
		paint();
		openSelected();
		return true;
	};

	const close = (): void => {
		setShowing(false);
		props.closed();
	};

	const stale = (): boolean => {
		const q = wanted();
		return ran === null || (ran as Query).text != q.text || (ran as Query).caseSensitive != q.caseSensitive
			|| (ran as Query).wholeWord != q.wholeWord;
	};

	const key = (e: NeonEvent): void => {
		match (e.key) {
			"Escape" => { close(); }
			"Enter" => {
				if (stale()) { run(); } else { openSelected(); }
			}
			"F3" => { const _stepped = step(!e.shiftKey); }
			"ArrowDown" | "ArrowUp" => {
				if (results !== null && (results as ProjectResults).matches > 0) {
					selected = stepped(results as ProjectResults, selected, e.key == "ArrowDown");
					paint();
				}
			}
			"c" when e.altKey => {
				caseSensitive = !caseSensitive;
				rerun();
			}
			"w" when e.altKey => {
				wholeWord = !wholeWord;
				rerun();
			}
			_ => {}
		}
	};

	props.handle({
		show: (): void => {
			setShowing(true);
			paint();
			if (input !== null) { (input as TextInputHandle).focus(); }
		},
		step,
	});

	return <Show when={showing()}>
		<View
			style={{ padding: PICKER_PADDING, backgroundColor: PANEL }}
			onLayout={(e: NeonEvent): void => {
				const inner = e.width - 2 * PICKER_PADDING;
				if (inner == width) { return; }
				width = inner;
				paint();
			}}
		>
			<Field
				value={query()}
				placeholder="Search the project"
				ref={(handle: TextInputHandle): void => {
					onSettled((): Cleanup | null => {
						input = handle;
						handle.focus();
						return (): void => { input = null; };
					});
				}}
				onChangeText={(text: string): void => { setQuery(text); }}
				onKeyDown={key}
			/>
			<Text style={{ height: props.rowHeight(), marginTop: PICKER_GAP }} cellWidth={props.cellWidth()} spans={note()} />
			<View
				style={{ height: SEARCH_ROWS * props.rowHeight(), overflow: "hidden" }}
			>
				<Overlay box={picked()} />
				{ForList<Row>({
					each: lines,
					children: (r: Accessor<Row>): NeonNode => <LineRow row={r()} cellWidth={props.cellWidth()} rowHeight={props.rowHeight()} />,
				})}
			</View>
		</View>
	</Show>;
}

when (testBuild) {
	function textOf(r: Row): string {
		let out = "";
		for (const s of r.spans) { out += s.text; }
		return out;
	}

	function resultsOf(): ProjectResults {
		const hit = (line: int32, from: int32, text: string): Hit => ({ line, from, to: from + 3, text, textFrom: 0 });
		return {
			files: [
				{ key: "a.ms", hits: [hit(0, 4, "let cat;"), hit(4, 0, "cat")] },
				{ key: "b.ms", hits: [hit(9, 1, "\tcat")] },
			],
			matches: 3,
			limitReached: false,
		};
	}

	test "a hit row shows its line number, then the line with its match marked" {
		const r = hitRow({ line: 11, from: 5, to: 8, text: "\tlet cat = 1;", textFrom: 0 }, 20);
		assert textOf(r) == "  12:  let cat = 1; ";
		const marked = r.spans.filter((s: TextSpan): boolean => s.style !== null && s.style !== undefined && (s.style as Style).backgroundColor == MATCH);
		assert marked.length == 1 && marked[0].text == "cat";
		assert textOf(hitRow({ line: 0, from: 0, to: 3, text: "cat and a long tail", textFrom: 0 }, 12)) == "  1: cat an…";
	}

	test "the rows from a scrolled top start inside a file's hits" {
		const r = resultsOf();
		const all = searchRows(r, (k: string): string => k, 0, 10, 16);
		assert all.length == 5 && textOf(all[0]) == "a.ms  2" + " ".repeat(9) && textOf(all[3]) == "b.ms  1" + " ".repeat(9);
		const tail = searchRows(r, (k: string): string => k, 2, 2, 16);
		assert tail.length == 2 && textOf(tail[0]).startsWith("  5: cat") && textOf(tail[1]).startsWith("b.ms");
	}

	test "the note counts matches and files and says when the limit cut the search" {
		assert searchNote(null) == "Enter searches the project";
		const r = resultsOf();
		assert searchNote(r) == "3 matches in 2 files";
		assert searchNote({ ...r, limitReached: true }) == "3 matches in 2 files · limit reached";
		assert searchNote({ files: [], matches: 0, limitReached: false }) == "no matches";
	}
}
