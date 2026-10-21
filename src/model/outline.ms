import { Editor } from "./editor";
import { MenuMove } from "./completer";
import { Selections, primaryRange, single } from "./selection";
import { FuzzyMatch, fuzzyMatch } from "../text/fuzzy";

export struct OutlineItem {
	name: string;
	kind: int32;
	depth: int32;
	from: int32;
	to: int32;
}

export interface SymbolProvider {
	ask: (done: (found: OutlineItem[] | null) => void) => int32;
	cancel: (id: int32) => void;
}

// One row of the outline. `positions` are the matched bytes of the item's name; a row with none
// is there as the parent of a match, or was matched only through its parents' names.
export struct OutlineRow {
	index: int32;
	positions: int32[];
	score: float64;
}

function atomsOf(query: string): string[] {
	return query.split(" ").filter((a: string): boolean => a.byteLength > 0);
}

// The document's symbols, nested and in document order, filtered by a query: one word matches
// names, several match each name with its parents' in front. An empty query lists them all and
// picks the deepest around the cursor; a query picks the best match and puts the cursor on it.
// Confirming keeps the cursor there, dismissing puts it back.
export class Outline {
	selected: int32 = 0;
	private editor: Editor;
	private provider: SymbolProvider;
	private told: (message: string) => void;
	private changed: () => void;
	private items: OutlineItem[] = [];
	private parents: int32[] = [];
	private listed: OutlineRow[] = [];
	private origin: Selections | null = null;
	private asked: int32 = -1;
	private seq: int32 = 0;

	constructor(editor: Editor, provider: SymbolProvider, told: (message: string) => void, changed: () => void) {
		this.editor = editor;
		this.provider = provider;
		this.told = told;
		this.changed = changed;
	}

	open(): void {
		this.dismiss();
		if (this.asked >= 0) { this.provider.cancel(this.asked); }
		this.seq += 1;
		const seq = this.seq;
		const id = this.provider.ask((found: OutlineItem[] | null): void => {
			if (seq != this.seq) { return; }
			this.asked = -1;
			if (found === null) {
				this.told("listing symbols failed");
				return;
			}
			this.show(found as OutlineItem[]);
		});
		if (id < 0) { this.told("no language server lists symbols in this file"); }
		else { this.asked = id; }
	}

	shown(): boolean { return this.origin !== null; }

	rows(): OutlineRow[] { return this.listed; }

	item(index: int32): OutlineItem { return this.items[index]; }

	search(query: string): void {
		if (!this.shown()) { return; }
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
		this.preview();
		this.changed();
	}

	confirm(): void {
		if (!this.shown()) { return; }
		if (this.selected < (this.listed.length as int32)) { this.preview(); }
		this.origin = null;
		this.close();
	}

	dismiss(): void {
		if (!this.shown()) { return; }
		this.editor.select(this.origin as Selections);
		this.close();
	}

	private show(found: OutlineItem[]): void {
		if (found.length == 0) {
			this.told("no symbols in this document");
			return;
		}
		this.items = found;
		this.parents = [];
		const open: int32[] = [];
		for (let i = 0; i < (found.length as int32); i++) {
			while ((open.length as int32) > found[i].depth) { open.pop(); }
			this.parents.push(open.length > 0 ? open[open.length - 1] : -1);
			open.push(i);
		}
		this.origin = this.editor.selections;
		this.filter("");
		this.changed();
	}

	private pathOf(index: int32): string {
		const p = this.parents[index];
		return p < 0 ? this.items[index].name : `${this.pathOf(p)} ${this.items[index].name}`;
	}

	private filter(query: string): void {
		const atoms = atomsOf(query);
		this.listed = [];
		this.selected = 0;
		const n = this.items.length as int32;
		if (atoms.length == 0) {
			const head = (this.origin as Selections).primaryRange().head;
			let deepest = -1;
			for (let i = 0; i < n; i++) {
				const it = this.items[i];
				this.listed.push({ index: i, positions: [], score: 0 });
				if (it.from <= head && head < it.to && (deepest < 0 || it.depth > this.items[deepest].depth)) { deepest = i; }
			}
			this.selected = Math.max(0, deepest);
			this.editor.select(this.origin as Selections);
			return;
		}
		const kept: boolean[] = [];
		const found: OutlineRow[] = [];
		for (let i = 0; i < n; i++) {
			kept.push(false);
			found.push({ index: i, positions: [], score: 0 });
			const name = this.items[i].name;
			if (atoms.length == 1) {
				const m = fuzzyMatch(atoms[0], name, true);
				if (m === null) { continue; }
				found[i] = { index: i, positions: (m as FuzzyMatch).positions, score: (m as FuzzyMatch).score };
				kept[i] = true;
				continue;
			}
			const path = this.pathOf(i);
			const leaf = (path.byteLength - name.byteLength) as int32;
			const positions: int32[] = [];
			let score: float64 = 0;
			let all = true;
			for (const atom of atoms) {
				const m = fuzzyMatch(atom, path, true);
				if (m === null) {
					all = false;
					break;
				}
				score += (m as FuzzyMatch).score;
				for (const p of (m as FuzzyMatch).positions) { if (p >= leaf) { positions.push(p - leaf); } }
			}
			if (!all) { continue; }
			positions.sort((a: int32, b: int32) => a - b);
			found[i] = { index: i, positions, score: positions.length > 0 ? score : 0 };
			kept[i] = true;
		}
		for (let i = n - 1; i >= 0; i--) {
			if (kept[i] && this.parents[i] >= 0) { kept[this.parents[i]] = true; }
		}
		let best = -1;
		for (let i = 0; i < n; i++) {
			if (!kept[i]) { continue; }
			const row = found[i];
			if (row.positions.length > 0 && (best < 0 || row.score > this.listed[best].score)) { best = this.listed.length as int32; }
			this.listed.push(row);
		}
		this.selected = Math.max(0, best);
		if (best >= 0) { this.preview(); }
	}

	private preview(): void {
		this.editor.select(single(this.items[this.listed[this.selected].index].from));
	}

	close(): void {
		if (this.asked >= 0) {
			this.provider.cancel(this.asked);
			this.asked = -1;
		}
		this.seq += 1;
		if (this.items.length == 0 && this.origin === null) { return; }
		this.items = [];
		this.parents = [];
		this.listed = [];
		this.selected = 0;
		this.origin = null;
		this.changed();
	}
}

when (testBuild) {
	import { Document } from "./document";

	class Fake {
		answers: Array<(found: OutlineItem[] | null) => void> = [];
		cancelled: int32[] = [];

		provider(): SymbolProvider {
			return {
				ask: (done: (found: OutlineItem[] | null) => void): int32 => {
					this.answers.push(done);
					return this.answers.length as int32;
				},
				cancel: (id: int32): void => { this.cancelled.push(id); },
			};
		}
	}

	function outlining(text: string): [Editor, Fake, Outline, string[]] {
		const e = new Editor(new Document(text));
		const fake = new Fake();
		const notes: string[] = [];
		return [e, fake, new Outline(e, fake.provider(), (m: string): void => { notes.push(m); }, (): void => {}), notes];
	}

	function sym(name: string, depth: int32, from: int32, to: int32): OutlineItem {
		return { name, kind: 5, depth, from, to };
	}

	const SOURCE = "class Shape {\n\tarea() {}\n\tdraw() {}\n}\nfunction drawAll() {}\n";
	const SYMBOLS = [sym("Shape", 0, 0, 37), sym("area", 1, 15, 24), sym("draw", 1, 26, 35), sym("drawAll", 0, 38, 59)];

	test "an empty query lists every symbol and picks the deepest around the cursor" {
		const [e, fake, outline, notes] = outlining(SOURCE);
		e.select(single(28));
		outline.open();
		fake.answers[0](SYMBOLS);
		assert outline.shown() && outline.rows().length == 4 && outline.selected == 2;
		assert e.selections.primaryRange().head == 28;
		outline.move(MenuMove.Next);
		assert outline.selected == 3 && e.selections.primaryRange().head == 38;
		outline.dismiss();
		assert !outline.shown() && e.selections.primaryRange().head == 28;
		e.select(single(60));
		outline.open();
		fake.answers[1](SYMBOLS);
		assert outline.selected == 0;
		outline.close();
		outline.open();
		fake.answers[2]([]);
		assert !outline.shown() && notes[0] == "no symbols in this document";
	}

	test "one word matches names and keeps their parents, picking the best and moving the cursor there" {
		const [e, fake, outline, _n] = outlining(SOURCE);
		e.select(single(0));
		outline.open();
		fake.answers[0](SYMBOLS);
		outline.search("draw");
		const rows = outline.rows();
		assert rows.length == 3 && rows[0].index == 0 && rows[0].positions.length == 0;
		assert rows[1].index == 2 && rows[2].index == 3 && rows[2].positions.length == 4;
		assert outline.selected == 1 && e.selections.primaryRange().head == 26;
		outline.search("shape draw");
		assert outline.rows().length == 2 && outline.rows()[1].index == 2;
		assert outline.rows()[1].positions.length == 4 && outline.selected == 1;
		outline.search("");
		assert outline.rows().length == 4 && e.selections.primaryRange().head == 0;
		outline.search("zzz");
		assert outline.rows().length == 0;
		outline.search("area");
		outline.confirm();
		assert !outline.shown() && e.selections.primaryRange().head == 15;
	}
}
