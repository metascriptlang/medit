import { MenuMove } from "./completer";
import { FuzzyMatch, charsOf, fuzzyMatch, isUpper } from "../text/fuzzy";

export const QUICK_OPEN_ROWS: int32 = 100;
const MAX_POSITION_DIGITS: int32 = 9;

export struct FileRow {
	index: int32;
	positions: int32[];
	score: float64;
}

function lowerByte(b: int32): int32 {
	return b >= "A".code && b <= "Z".code ? b + 32 : b;
}

function nameStart(path: string): int32 {
	for (let i = (path.byteLength as int32) - 1; i >= 0; i--) {
		if (path.byteAt(i) == "/".code) { return i + 1; }
	}
	return 0;
}

function isNumber(text: string): boolean {
	const n = text.byteLength as int32;
	if (n == 0 || n > MAX_POSITION_DIGITS) { return false; }
	for (let i = 0; i < n; i++) {
		const b = text.byteAt(i);
		if (b < "0".code || b > "9".code) { return false; }
	}
	return true;
}

function trimmedColons(text: string): string {
	let end = text.byteLength as int32;
	while (end > 0 && text.byteAt(end - 1) == ":".code) { end -= 1; }
	return text.byteSlice(0, end);
}

function mayMatch(path: string, from: int32, wanted: int32[]): boolean {
	const n = path.byteLength as int32;
	let at = from;
	for (const want of wanted) {
		if (want >= 0x80) { continue; }
		let found = false;
		while (at < n && !found) {
			const have = lowerByte(path.byteAt(at));
			found = have == want || (want == "_".code && have == "/".code);
			at += 1;
		}
		if (!found) { return false; }
	}
	return true;
}

function startsWithFolded(path: string, from: int32, wanted: int32[]): boolean {
	if (from + (wanted.length as int32) > (path.byteLength as int32)) { return false; }
	for (let i = 0; i < (wanted.length as int32); i++) {
		if (lowerByte(path.byteAt(from + i)) != wanted[i]) { return false; }
	}
	return true;
}

function ahead(score: float64, path: string, otherScore: float64, otherPath: string): boolean {
	if (score != otherScore) { return score > otherScore; }
	if (path.byteLength != otherPath.byteLength) { return path.byteLength < otherPath.byteLength; }
	return path < otherPath;
}

export class QuickOpen {
	selected: int32 = 0;
	private paths: string[] = [];
	private names: int32[] = [];
	private indexOf: Map<string, int32> = new Map<string, int32>();
	private recentPaths: string[] = [];
	private recentIndex: int32[] = [];
	private currentPath: string | null = null;
	private currentIndex: int32 = -1;
	private outside: string[] = [];
	private listed: FileRow[] = [];
	private showingNow: boolean = false;
	private typed: string = "";
	private wanted: string = "";
	private wantedBytes: int32[] = [];
	private wantedChars: int32 = 0;
	private wholePath: boolean = false;
	private smartCase: boolean = false;
	private atLine: int32 | null = null;
	private atColumn: int32 | null = null;
	private survivors: int32[] = [];
	private survivorsFor: string | null = null;
	private changed: () => void;

	constructor(changed: () => void) {
		this.changed = changed;
	}

	files(paths: string[]): void {
		this.paths = paths;
		this.names = paths.map((p: string): int32 => nameStart(p));
		this.indexOf = new Map<string, int32>();
		for (let i = 0; i < (paths.length as int32); i++) { this.indexOf.set(paths[i], i); }
		this.survivorsFor = null;
		this.placeHistory();
		this.refresh();
	}

	history(recent: string[], current: string | null): void {
		this.recentPaths = recent;
		this.currentPath = current;
		this.placeHistory();
		this.refresh();
	}

	show(): void {
		this.showingNow = true;
		this.filter("");
		this.changed();
	}

	hide(): void {
		if (!this.showingNow) { return; }
		this.showingNow = false;
		this.listed = [];
		this.selected = 0;
		this.typed = "";
		this.changed();
	}

	showing(): boolean { return this.showingNow; }

	query(text: string): void {
		if (!this.showingNow) { return; }
		this.filter(text);
		this.changed();
	}

	rows(): FileRow[] { return this.listed; }

	path(row: FileRow): string { return this.candidate(row.index); }

	line(): int32 | null { return this.atLine; }

	column(): int32 | null { return this.atColumn; }

	move(m: MenuMove): void {
		const n = this.listed.length as int32;
		if (n == 0) { return; }
		this.selected = match (m) {
			MenuMove.Previous => this.selected > 0 ? this.selected - 1 : n - 1,
			MenuMove.Next => this.selected + 1 < n ? this.selected + 1 : 0,
			MenuMove.First => 0,
			MenuMove.Last => n - 1,
		};
		this.changed();
	}

	chosen(): string | null {
		if (this.selected >= (this.listed.length as int32)) { return null; }
		return this.path(this.listed[this.selected]);
	}

	private candidate(index: int32): string {
		const n = this.paths.length as int32;
		return index < n ? this.paths[index] : this.outside[index - n];
	}

	private nameOf(index: int32): int32 {
		const n = this.paths.length as int32;
		return index < n ? this.names[index] : nameStart(this.outside[index - n]);
	}

	private placeHistory(): void {
		this.outside = [];
		this.recentIndex = [];
		this.currentIndex = -1;
		const placed = new Map<int32, boolean>();
		const ordered: string[] = this.currentPath === null ? [] : [this.currentPath as string];
		for (const p of this.recentPaths) { ordered.push(p); }
		for (const p of ordered) {
			const known = this.indexOf.get(p);
			let index = 0;
			if (known === undefined) {
				this.outside.push(p);
				index = (this.paths.length as int32) + (this.outside.length as int32) - 1;
			} else {
				index = known as int32;
			}
			if (placed.has(index)) { continue; }
			placed.set(index, true);
			if (p == this.currentPath) { this.currentIndex = index; }
			this.recentIndex.push(index);
		}
	}

	private refresh(): void {
		if (!this.showingNow) { return; }
		this.filter(this.typed);
		this.changed();
	}

	private parse(text: string): void {
		this.typed = text;
		const compact = trimmedColons(text.split(" ").join("").split("\t").join(""));
		const parts = compact.split(":");
		const n = parts.length as int32;
		this.atLine = null;
		this.atColumn = null;
		this.wanted = compact;
		if (n >= 2 && isNumber(parts[n - 1])) {
			const columned = n >= 3 && isNumber(parts[n - 2]);
			const kept = columned ? n - 2 : n - 1;
			const path = trimmedColons(parts.slice(0, kept).join(":"));
			if (path.byteLength > 0) {
				this.wanted = path;
				this.atLine = parseInt(parts[kept]) as int32;
				this.atColumn = columned ? parseInt(parts[n - 1]) as int32 : null;
			}
		}
		const chars = charsOf(this.wanted).text;
		this.wantedChars = chars.length as int32;
		this.wholePath = this.wanted.indexOf("/") >= 0;
		this.smartCase = false;
		for (const c of chars) {
			if (isUpper(c)) { this.smartCase = true; }
		}
		this.wantedBytes = [];
		for (let i = 0; i < (this.wanted.byteLength as int32); i++) {
			this.wantedBytes.push(lowerByte(this.wanted.byteAt(i)));
		}
	}

	private prefixed(index: int32): boolean {
		const from = this.wholePath ? 0 : this.names[index];
		return startsWithFolded(this.paths[index], from, this.wantedBytes);
	}

	private loses(score: float64, path: string, worst: FileRow | null): boolean {
		if (worst === null) { return false; }
		const last = worst as FileRow;
		return !ahead(score, path, last.score, this.candidate(last.index));
	}

	private matched(index: int32, worst: FileRow | null, history: boolean): FileRow | null {
		const path = this.candidate(index);
		const nameAt = this.nameOf(index);
		const chars = this.wantedChars as float64;
		if (!this.wholePath && mayMatch(path, nameAt, this.wantedBytes)) {
			if (this.loses(chars * 2, path, worst)) { return null; }
			const name = path.byteSlice(nameAt, path.byteLength);
			const m = fuzzyMatch(this.wanted, name, this.smartCase);
			if (m !== null) {
				const hit = m as FuzzyMatch;
				return {
					index,
					positions: hit.positions.map((p: int32): int32 => p + nameAt),
					score: hit.score + chars,
				};
			}
		}
		if ((history && !this.wholePath) || this.loses(chars, path, worst)) { return null; }
		const m = fuzzyMatch(this.wanted, path, this.smartCase);
		if (m === null) { return null; }
		return { index, positions: (m as FuzzyMatch).positions, score: (m as FuzzyMatch).score };
	}

	private kept(rows: FileRow[], row: FileRow, limit: int32): void {
		rows.push(row);
		for (let i = (rows.length as int32) - 1; i > 0; i--) {
			const later = rows[i];
			const earlier = rows[i - 1];
			const laterPath = this.candidate(later.index);
			const earlierPath = this.candidate(earlier.index);
			if (!ahead(later.score, laterPath, earlier.score, earlierPath)) { break; }
			rows[i] = earlier;
			rows[i - 1] = later;
		}
		if ((rows.length as int32) > limit) { rows.pop(); }
	}

	private filter(text: string): void {
		const before = this.survivorsFor;
		this.parse(text);
		this.selected = 0;
		this.listed = [];
		if (this.wanted.byteLength == 0) {
			for (const index of this.recentIndex) {
				if ((this.listed.length as int32) == QUICK_OPEN_ROWS) { break; }
				this.listed.push({ index, positions: [], score: 0 });
			}
			return;
		}
		const shown = new Map<int32, boolean>();
		for (const index of this.recentIndex) {
			const row = this.matched(index, null, true);
			if (row !== null) {
				this.kept(this.listed, row as FileRow, QUICK_OPEN_ROWS);
				shown.set(index, true);
			}
		}
		for (let i = 1; i < (this.listed.length as int32); i++) {
			if (this.listed[i].index != this.currentIndex) { continue; }
			const row = this.listed[i];
			for (let k = i; k > 0; k--) { this.listed[k] = this.listed[k - 1]; }
			this.listed[0] = row;
		}
		const room = QUICK_OPEN_ROWS - (this.listed.length as int32);
		const narrowed = before !== null && this.wanted.startsWith(before as string);
		const pool: int32[] = narrowed ? this.survivors : [];
		if (!narrowed) {
			for (let i = 0; i < (this.paths.length as int32); i++) { pool.push(i); }
		}
		const found: FileRow[] = [];
		const passed: int32[] = [];
		for (const index of pool) {
			if (room == 0 || shown.has(index) || !this.prefixed(index)) { continue; }
			const worst = (found.length as int32) == room ? found[room - 1] : null;
			const row = this.matched(index, worst, false);
			if (row !== null) { this.kept(found, row as FileRow, room); }
		}
		for (const index of pool) {
			if (!mayMatch(this.paths[index], 0, this.wantedBytes)) { continue; }
			passed.push(index);
			if (room == 0 || shown.has(index) || this.prefixed(index)) { continue; }
			const worst = (found.length as int32) == room ? found[room - 1] : null;
			const row = this.matched(index, worst, false);
			if (row !== null) { this.kept(found, row as FileRow, room); }
		}
		this.survivors = passed;
		this.survivorsFor = this.wanted;
		for (const row of found) { this.listed.push(row); }
		const skipsCurrent = this.atLine === null && (this.listed.length as int32) > 1 && this.listed[0].index == this.currentIndex;
		if (skipsCurrent) { this.selected = 1; }
	}
}

when (testBuild) {
	function listed(open: QuickOpen): string {
		return open.rows().map((r: FileRow): string => open.path(r)).join(",");
	}

	function opened(paths: string[]): [QuickOpen, int32[]] {
		const changes: int32[] = [0];
		const open = new QuickOpen((): void => { changes[0] += 1; });
		open.files(paths);
		return [open, changes];
	}

	test "a hit in the file name ranks above a hit across directories" {
		const [open, changes] = opened([
			"tabs/view/strip.ms",
			"src/model/tabs.ms",
			"src/app/tabsBar.ms",
		]);
		open.show();
		assert open.showing() && changes[0] == 1;
		open.query("tabs");
		assert listed(open) == "src/model/tabs.ms,src/app/tabsBar.ms,tabs/view/strip.ms";
		const hit = open.rows()[0].positions;
		assert hit.length == 4 && hit[0] == 10 && hit[3] == 13;
		open.query("tvs");
		assert listed(open) == "tabs/view/strip.ms";
		open.query("zzz");
		assert open.rows().length == 0 && open.chosen() === null;
	}

	test "a query with a slash matches the whole path" {
		const [open, _c] = opened(["src/model/tabs.ms", "src/model/quickOpen.ms", "model.ms"]);
		open.show();
		open.query("model/t");
		assert listed(open) == "src/model/tabs.ms";
		open.query("model");
		assert open.path(open.rows()[0]) == "model.ms";
	}

	test "an empty query lists the history, and a query ranks history matches first" {
		const [open, _c] = opened(["a/main.ms", "b/main.ms", "b/mainly.ms", "c/other.ms"]);
		open.history(["b/mainly.ms", "c/other.ms", "/elsewhere/main.ms"], null);
		open.show();
		assert listed(open) == "b/mainly.ms,c/other.ms,/elsewhere/main.ms";
		open.query("main");
		assert listed(open) == "b/mainly.ms,/elsewhere/main.ms,a/main.ms,b/main.ms";
		open.query("other");
		assert listed(open) == "c/other.ms";
		open.query("c");
		assert open.path(open.rows()[0]) == "c/other.ms";
	}

	test "the open file leads the history and a query selects past it to the next match" {
		const [open, _c] = opened(["a/main.ms", "b/main.ms", "c/other.ms"]);
		open.history(["c/other.ms", "a/main.ms"], "b/main.ms");
		open.show();
		assert listed(open) == "b/main.ms,c/other.ms,a/main.ms";
		assert open.chosen() == "b/main.ms";
		open.query("main");
		assert listed(open) == "b/main.ms,a/main.ms";
		assert open.chosen() == "a/main.ms";
		open.query("main:3");
		assert open.chosen() == "b/main.ms";
		open.query("b/main");
		assert listed(open) == "b/main.ms";
		assert open.chosen() == "b/main.ms";
	}

	test "a :line and :line:col suffix is read off the query" {
		const [open, _c] = opened(["src/model/tabs.ms", "src/a:b.ms"]);
		open.show();
		open.query("tabs.ms:12:4");
		assert open.line() == 12 && open.column() == 4 && listed(open) == "src/model/tabs.ms";
		open.query("tabs:7:");
		assert open.line() == 7 && open.column() === null && listed(open) == "src/model/tabs.ms";
		open.query("tabs::3");
		assert open.line() == 3 && listed(open) == "src/model/tabs.ms";
		open.query("a:b");
		assert open.line() === null && listed(open) == "src/a:b.ms";
		open.query("tabs");
		assert open.line() === null && open.column() === null;
	}

	test "narrowing a query reuses the paths that matched, and widening scans them all" {
		const [open, _c] = opened(["one.ms", "two.ms", "three.ms"]);
		open.show();
		open.query("t");
		open.query("tw");
		assert listed(open) == "two.ms";
		open.query("o");
		assert listed(open) == "one.ms,two.ms";
		open.files(["one.ms", "four.ms"]);
		assert listed(open) == "one.ms,four.ms";
	}

	test "rows stop at the bound, moving wraps, and the chosen path is the selected row" {
		const paths: string[] = [];
		for (let i = 0; i < QUICK_OPEN_ROWS * 3; i++) { paths.push(`dir${i}/file${i}.ms`); }
		const [open, _c] = opened(paths);
		open.show();
		open.query("file");
		assert (open.rows().length as int32) == QUICK_OPEN_ROWS;
		assert open.chosen() == "dir0/file0.ms";
		open.move(MenuMove.Previous);
		assert open.selected == QUICK_OPEN_ROWS - 1;
		open.move(MenuMove.Next);
		assert open.selected == 0;
		open.move(MenuMove.Next);
		assert open.chosen() == "dir1/file1.ms";
		open.hide();
		assert !open.showing() && open.rows().length == 0;
		open.query("file");
		assert open.rows().length == 0;
	}
}
