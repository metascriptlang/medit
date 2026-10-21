import { Anchor, Bias } from "./document";
import { Editor } from "./editor";
import { MenuMove } from "./completer";
import { Selections, end, primaryRange, single, start } from "./selection";

export struct Place {
	uri: string;
	line: int32;
	character: int32;
	here: [int32, int32] | null;
}

export interface ReferenceProvider {
	ask: (offset: int32, done: (found: Place[] | null) => void) => int32;
	cancel: (id: int32) => void;
}

struct Held {
	place: Place;
	from: Anchor | null;
	to: Anchor | null;
}

function before(a: Place, b: Place): number {
	const aHere = a.here !== null;
	const bHere = b.here !== null;
	if (aHere != bHere) { return aHere ? -1 : 1; }
	if (aHere) {
		const [af, at] = a.here as [int32, int32];
		const [bf, bt] = b.here as [int32, int32];
		return af != bf ? af - bf : bt - at;
	}
	if (a.uri != b.uri) { return a.uri < b.uri ? -1 : 1; }
	return a.line != b.line ? a.line - b.line : a.character - b.character;
}

function same(a: Place, b: Place): boolean {
	if (a.here !== null && b.here !== null) {
		const [af, at] = a.here as [int32, int32];
		const [bf, bt] = b.here as [int32, int32];
		return af == bf && at == bt;
	}
	return a.here === null && b.here === null && a.uri == b.uri && a.line == b.line && a.character == b.character;
}

// The places that refer to the symbol under the primary cursor, this document's first in
// document order. With one place besides the cursor's own the cursor goes there; with more they
// are listed, and moving through the list puts the cursor on each, until the list is confirmed
// or dismissed, which puts it back.
export class References {
	selected: int32 = 0;
	private editor: Editor;
	private provider: ReferenceProvider;
	private told: (message: string) => void;
	private changed: () => void;
	private away: (p: Place) => string | null;
	private held: Held[] = [];
	private origin: Selections | null = null;
	private asked: int32 = -1;
	private seq: int32 = 0;

	constructor(
		editor: Editor,
		provider: ReferenceProvider,
		told: (message: string) => void,
		changed: () => void,
		away: (p: Place) => string | null,
	) {
		this.editor = editor;
		this.provider = provider;
		this.told = told;
		this.changed = changed;
		this.away = away;
	}

	private go(p: Place): void {
		const failed = this.away(p);
		if (failed !== null) { this.told(failed as string); }
	}

	find(): void {
		this.dismiss();
		if (this.asked >= 0) { this.provider.cancel(this.asked); }
		this.seq += 1;
		const seq = this.seq;
		const r = this.editor.selections.primaryRange();
		const id = this.provider.ask(r.head, (found: Place[] | null): void => {
			if (seq != this.seq) { return; }
			this.asked = -1;
			if (found === null) {
				this.told("finding references failed");
				return;
			}
			this.show(found as Place[]);
		});
		if (id < 0) { this.told("no language server finds references in this file"); }
		else { this.asked = id; }
	}

	shown(): boolean { return this.held.length > 0; }

	// The listed places, offsets as the document is now.
	places(): Place[] {
		const doc = this.editor.doc;
		return this.held.map((h: Held): Place => {
			if (h.from === null) { return h.place; }
			const from = doc.resolve(h.from as Anchor);
			return { ...h.place, here: [from, Math.max(from, doc.resolve(h.to as Anchor))] };
		});
	}

	move(m: MenuMove): void {
		const n = this.held.length as int32;
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
		const p = this.places()[this.selected];
		this.close();
		if (p.here === null) { this.go(p); }
	}

	dismiss(): void {
		if (!this.shown()) { return; }
		if (this.origin !== null) { this.editor.select(this.origin as Selections); }
		this.close();
	}

	private show(found: Place[]): void {
		const sorted = found.slice(0);
		sorted.sort(before);
		const list: Place[] = [];
		for (const p of sorted) {
			if (list.length == 0 || !same(list[list.length - 1], p)) { list.push(p); }
		}
		const r = this.editor.selections.primaryRange();
		const from = r.start();
		const to = r.end();
		const covers = (p: Place): boolean => p.here !== null && (p.here as [int32, int32])[0] <= from && to <= (p.here as [int32, int32])[1];
		const others = list.filter((p: Place): boolean => !covers(p));
		if (others.length == 0) {
			this.told(list.length == 0 ? "no references found" : "no other references found");
			return;
		}
		if (others.length == 1) {
			const p = others[0];
			if (p.here === null) { this.go(p); }
			else { this.editor.select(single((p.here as [int32, int32])[0])); }
			this.changed();
			return;
		}
		const doc = this.editor.doc;
		this.held = list.map((p: Place): Held => p.here === null ? { place: p, from: null, to: null } : {
			place: p,
			from: doc.anchor((p.here as [int32, int32])[0], Bias.Left),
			to: doc.anchor((p.here as [int32, int32])[1], Bias.Right),
		});
		this.origin = this.editor.selections;
		this.selected = 0;
		for (let i = (list.length as int32) - 1; i >= 0; i--) {
			if (covers(list[i])) { this.selected = i; }
		}
		this.changed();
	}

	private preview(): void {
		const p = this.places()[this.selected];
		if (p.here !== null) { this.editor.select(single((p.here as [int32, int32])[0])); }
	}

	close(): void {
		if (!this.shown()) { return; }
		const doc = this.editor.doc;
		for (const h of this.held) {
			if (h.from !== null) {
				doc.release(h.from as Anchor);
				doc.release(h.to as Anchor);
			}
		}
		this.held = [];
		this.selected = 0;
		this.origin = null;
		this.changed();
	}
}

when (testBuild) {
	import { Document } from "./document";

	class Fake {
		asks: int32[] = [];
		answers: Array<(found: Place[] | null) => void> = [];
		cancelled: int32[] = [];

		provider(): ReferenceProvider {
			return {
				ask: (offset: int32, done: (found: Place[] | null) => void): int32 => {
					this.asks.push(offset);
					this.answers.push(done);
					return this.answers.length as int32;
				},
				cancel: (id: int32): void => { this.cancelled.push(id); },
			};
		}
	}

	function finding(text: string): [Editor, Fake, References, string[]] {
		const e = new Editor(new Document(text));
		const fake = new Fake();
		const notes: string[] = [];
		const away = (p: Place): string | null => `${p.uri}:${p.line + 1}:${p.character + 1} is not open`;
		return [e, fake, new References(e, fake.provider(), (m: string): void => { notes.push(m); }, (): void => {}, away), notes];
	}

	function at(from: int32, to: int32): Place {
		return { uri: "file:///a.ms", line: 0, character: from, here: [from, to] };
	}

	test "references are listed in document order with others after, and moving previews each" {
		const [e, fake, refs, notes] = finding("ab + ab + ab");
		e.select(single(6));
		refs.find();
		assert fake.asks[0] == 6;
		const other: Place = { uri: "file:///b.ms", line: 3, character: 2, here: null };
		fake.answers[0]([other, at(10, 12), at(5, 7), at(0, 2), at(5, 7)]);
		assert refs.shown() && refs.places().length == 4 && refs.places()[3].here === null;
		assert refs.selected == 1;
		refs.move(MenuMove.Next);
		assert e.selections.primaryRange().head == 10;
		refs.move(MenuMove.Last);
		assert refs.selected == 3 && e.selections.primaryRange().head == 10;
		refs.confirm();
		assert !refs.shown() && notes[0] == "file:///b.ms:4:3 is not open";
		refs.find();
		fake.answers[1]([at(0, 2), at(5, 7), at(10, 12)]);
		refs.move(MenuMove.Previous);
		assert refs.selected == 1 && e.selections.primaryRange().head == 5;
		refs.dismiss();
		assert e.selections.primaryRange().head == 10 && !refs.shown();
	}

	test "one other reference is jumped to, none is told, and a failure is told" {
		const [e, fake, refs, notes] = finding("ab + ab");
		e.select(single(1));
		refs.find();
		fake.answers[0]([at(0, 2), at(5, 7)]);
		assert !refs.shown() && e.selections.primaryRange().head == 5;
		refs.find();
		fake.answers[1]([at(5, 7)]);
		assert notes[0] == "no other references found";
		refs.find();
		fake.answers[2](null);
		assert notes[1] == "finding references failed";
	}
}
