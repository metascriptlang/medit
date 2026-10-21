import { MenuMove } from "./completer";
import { FuzzyMatch, charsOf, fuzzyMatch, isLower, isUpper, lowered } from "../text/fuzzy";

export struct PaletteCommand {
	name: string;
	title: string;
	key: string;
}

export struct PaletteRow {
	index: int32;
	positions: int32[];
	score: float64;
}

const NEVER_RUN: int32 = -1;

function spaced(text: string): string {
	return text.byteLength > 0 && !text.endsWith(" ") ? " " : "";
}

export function humanized(name: string): string {
	const chars = charsOf(name).text;
	const n = chars.length as int32;
	let out = "";
	let i = 0;
	while (i < n) {
		if (!isUpper(chars[i])) {
			out += chars[i];
			i += 1;
			continue;
		}
		let end = i + 1;
		while (end < n && isUpper(chars[end])) { end += 1; }
		const run = end - i;
		const acronym = run == 1 ? 0 : end < n && isLower(chars[end]) ? run - 1 : run;
		if (acronym > 0) { out += spaced(out) + chars.slice(i, i + acronym).join(""); }
		if (acronym < run) { out += spaced(out) + lowered(chars[i + acronym]); }
		i = end;
	}
	return out;
}

export class Palette {
	selected: int32 = 0;
	private commands: PaletteCommand[] = [];
	private lastRun: Map<string, int32> = new Map<string, int32>();
	private runs: int32 = 0;
	private listed: PaletteRow[] = [];
	private showing: boolean = false;
	private changed: () => void;

	constructor(names: string[], keys: Map<string, string>, changed: () => void) {
		for (const name of names) {
			const key = keys.get(name);
			this.commands.push({ name, title: humanized(name), key: key === undefined ? "" : key as string });
		}
		this.changed = changed;
	}

	open(): void {
		this.showing = true;
		this.filter("");
		this.changed();
	}

	shown(): boolean { return this.showing; }

	rows(): PaletteRow[] { return this.listed; }

	command(index: int32): PaletteCommand { return this.commands[index]; }

	all(): PaletteCommand[] { return this.commands; }

	search(query: string): void {
		if (!this.showing) { return; }
		this.filter(query);
		this.changed();
	}

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

	confirm(): string | null {
		if (!this.showing) { return null; }
		let picked: string | null = null;
		if (this.selected < (this.listed.length as int32)) {
			const name = this.commands[this.listed[this.selected].index].name;
			this.runs += 1;
			this.lastRun.set(name, this.runs);
			picked = name;
		}
		this.close();
		return picked;
	}

	close(): void {
		if (!this.showing) { return; }
		this.showing = false;
		this.listed = [];
		this.selected = 0;
		this.changed();
	}

	private ranOf(index: int32): int32 {
		const at = this.lastRun.get(this.commands[index].name);
		return at === undefined ? NEVER_RUN : at as int32;
	}

	private ranked(a: PaletteRow, b: PaletteRow): int32 {
		const ranA = this.ranOf(a.index);
		const ranB = this.ranOf(b.index);
		if (ranA != ranB) { return ranB - ranA; }
		if (a.score != b.score) { return a.score > b.score ? -1 : 1; }
		const titleA = this.commands[a.index].title;
		const titleB = this.commands[b.index].title;
		return titleA < titleB ? -1 : titleA > titleB ? 1 : 0;
	}

	private filter(query: string): void {
		const wanted = query.split(" ").filter((a: string): boolean => a.byteLength > 0).join(" ");
		const found: PaletteRow[] = [];
		for (let i = 0; i < (this.commands.length as int32); i++) {
			const m = fuzzyMatch(wanted, this.commands[i].title, true);
			if (m === null) { continue; }
			found.push({ index: i, positions: (m as FuzzyMatch).positions, score: (m as FuzzyMatch).score });
		}
		found.sort((a: PaletteRow, b: PaletteRow): number => this.ranked(a, b));
		this.listed = found;
		this.selected = 0;
	}
}

when (testBuild) {
	function titles(palette: Palette): string {
		return palette.rows().map((r: PaletteRow): string => palette.command(r.index).title).join(",");
	}

	function paletteOver(names: string[]): [Palette, int32[]] {
		const keys = new Map<string, string>();
		keys.set("undo", "ctrl+z");
		const changes: int32[] = [0];
		return [new Palette(names, keys, (): void => { changes[0] += 1; }), changes];
	}

	test "a command's title splits its name at case changes and keeps an acronym whole" {
		assert humanized("goToDefinition") == "go to definition";
		assert humanized("undo") == "undo";
		assert humanized("toX") == "to x";
		assert humanized("openURL") == "open URL";
		assert humanized("openURLParser") == "open URL parser";
	}

	test "an empty query lists every command by title with its key, and a query matches titles" {
		const [palette, changes] = paletteOver(["undo", "selectAll", "goToLine", "redo"]);
		palette.open();
		assert palette.shown() && changes[0] == 1;
		assert titles(palette) == "go to line,redo,select all,undo";
		assert palette.command(palette.rows()[3].index).key == "ctrl+z";
		assert palette.command(palette.rows()[0].index).key == "";
		palette.search("  go   li ");
		assert titles(palette) == "go to line";
		const hit = palette.rows()[0].positions;
		assert hit.length == 5 && hit[0] == 0 && hit[1] == 1 && hit[3] == 6 && hit[4] == 7;
		palette.search("do");
		assert titles(palette) == "redo,undo";
		palette.search("l");
		assert titles(palette) == "go to line,select all";
		palette.search("zzz");
		assert palette.rows().length == 0 && palette.confirm() === null && !palette.shown();
	}

	test "moving wraps, confirming names the command and closes, and closing names none" {
		const [palette, _c] = paletteOver(["undo", "selectAll", "goToLine"]);
		palette.open();
		palette.move(MenuMove.Previous);
		assert palette.selected == 2;
		palette.move(MenuMove.Next);
		assert palette.selected == 0;
		palette.move(MenuMove.Last);
		assert palette.confirm() == "undo" && !palette.shown() && palette.rows().length == 0;
		palette.open();
		palette.close();
		assert !palette.shown() && palette.confirm() === null;
	}

	test "commands run from the palette come first, the latest first, ahead of a better match" {
		const [palette, _c] = paletteOver(["undo", "selectAll", "goToLine", "redo"]);
		palette.open();
		palette.search("redo");
		assert palette.confirm() == "redo";
		palette.open();
		palette.search("select");
		assert palette.confirm() == "selectAll";
		palette.open();
		assert titles(palette) == "select all,redo,go to line,undo";
		palette.search("l");
		assert titles(palette) == "select all,go to line";
	}
}
