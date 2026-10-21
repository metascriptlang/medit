import { Anchor, Bias, Document, Edit } from "./document";
import { Editor } from "./editor";
import { acceptLater, wordAround } from "./completion";
import { primaryRange } from "./selection";

export interface RenameProvider {
	prepares: () => boolean;
	prepare: (offset: int32, done: (range: [int32, int32] | null, error: string | null) => void) => int32;
	rename: (offset: int32, name: string, done: (edits: Edit[] | null, others: int32, error: string | null) => void) => int32;
	cancel: (id: int32) => void;
}

// The name being edited: its place in the document, the name it had, and the part of it the
// person's selection covered, as offsets into the name.
export struct Renaming {
	from: int32;
	to: int32;
	old: string;
	selectFrom: int32;
	selectTo: int32;
}

// Renames the symbol under the primary cursor: the server, or the word there, names its range,
// the person edits the name, and the server's edits to this document apply as one undo step.
// An answer that also edits other documents is refused whole, so no rename is left half done.
export class Renamer {
	private editor: Editor;
	private provider: RenameProvider;
	private told: (message: string) => void;
	private changed: () => void;
	private from: Anchor | null = null;
	private to: Anchor | null = null;
	private old: string = "";
	private selectFrom: int32 = 0;
	private selectTo: int32 = 0;
	private asked: int32 = -1;
	private seq: int32 = 0;

	constructor(editor: Editor, provider: RenameProvider, told: (message: string) => void, changed: () => void) {
		this.editor = editor;
		this.provider = provider;
		this.told = told;
		this.changed = changed;
	}

	// Opens the rename of the symbol under the primary cursor, at once on the word there when
	// the server cannot say where a rename applies.
	start(): void {
		this.cancel();
		const doc = this.editor.doc;
		const r = this.editor.selections.primaryRange();
		const head = r.head;
		const tail = r.anchor;
		if (!this.provider.prepares()) {
			const [from, to] = wordAround(doc, head);
			if (from == to) { this.told("nothing to rename here"); }
			else { this.open(from, to, head, tail); }
			return;
		}
		const seq = this.seq;
		const version = doc.version();
		const id = this.provider.prepare(head, (range: [int32, int32] | null, error: string | null): void => {
			if (seq != this.seq) { return; }
			this.asked = -1;
			if (error !== null) { this.told(`rename failed: ${error as string}`); }
			else if (range === null) { this.told("nothing to rename here"); }
			else {
				const [from, to] = range as [int32, int32];
				this.open(from, to, doc.offsetSince(version, head, Bias.Right), doc.offsetSince(version, tail, Bias.Right));
			}
		});
		if (id < 0) { this.told("no language server renames in this file"); }
		else { this.asked = id; }
	}

	renaming(): Renaming | null {
		if (this.from === null) { return null; }
		const doc = this.editor.doc;
		const from = doc.resolve(this.from as Anchor);
		return { from, to: Math.max(from, doc.resolve(this.to as Anchor)), old: this.old, selectFrom: this.selectFrom, selectTo: this.selectTo };
	}

	// Renames to `name`; an empty name, or the old one, ends the rename with no change.
	confirm(name: string): void {
		const at = this.renaming();
		this.cancel();
		if (at === null || name.trim() == "" || name == (at as Renaming).old) { return; }
		const seq = this.seq;
		const doc = this.editor.doc;
		const version = doc.version();
		const id = this.provider.rename((at as Renaming).from, name, (edits: Edit[] | null, others: int32, error: string | null): void => {
			if (seq != this.seq) { return; }
			this.asked = -1;
			if (error !== null) {
				this.told(`rename failed: ${error as string}`);
				return;
			}
			const skipped = acceptLater(this.editor, edits as Edit[], doc.version(), "");
			if (skipped > 0) { this.told(`left out ${skipped} rename edit${skipped == 1 ? "" : "s"} that overlap another`); }
			else if (others > 0) { this.told(`rename also changed ${others} other file${others == 1 ? "" : "s"}, not saved yet`); }
		});
		if (id < 0) {
			this.told("no language server renames in this file");
			return;
		}
		this.asked = id;
	}

	cancel(): void {
		if (this.asked >= 0) { this.provider.cancel(this.asked); }
		this.asked = -1;
		this.seq += 1;
		if (this.from === null) { return; }
		this.editor.doc.release(this.from as Anchor);
		this.editor.doc.release(this.to as Anchor);
		this.from = null;
		this.to = null;
		this.changed();
	}

	private open(from: int32, to: int32, head: int32 | null, tail: int32 | null): void {
		const doc = this.editor.doc;
		this.from = doc.anchor(from, Bias.Left);
		this.to = doc.anchor(to, Bias.Right);
		this.old = doc.slice(from, to);
		const inside = (x: int32 | null): boolean => x !== null && (x as int32) >= from && (x as int32) <= to;
		const whole = head === null || tail === null || head == tail || !inside(head) || !inside(tail);
		this.selectFrom = whole ? 0 : Math.min(head as int32, tail as int32) - from;
		this.selectTo = whole ? to - from : Math.max(head as int32, tail as int32) - from;
		this.changed();
	}
}

when (testBuild) {
	import { single, span } from "./selection";

	class Fake {
		prepared: boolean = false;
		prepares: int32[] = [];
		prepareAnswers: Array<(range: [int32, int32] | null, error: string | null) => void> = [];
		renames: Array<[int32, string]> = [];
		renameAnswers: Array<(edits: Edit[] | null, others: int32, error: string | null) => void> = [];
		cancelled: int32[] = [];

		provider(): RenameProvider {
			return {
				prepares: (): boolean => this.prepared,
				prepare: (offset: int32, done: (range: [int32, int32] | null, error: string | null) => void): int32 => {
					this.prepares.push(offset);
					this.prepareAnswers.push(done);
					return this.prepareAnswers.length as int32;
				},
				rename: (offset: int32, name: string, done: (edits: Edit[] | null, others: int32, error: string | null) => void): int32 => {
					this.renames.push([offset, name]);
					this.renameAnswers.push(done);
					return 100 + (this.renameAnswers.length as int32);
				},
				cancel: (id: int32): void => { this.cancelled.push(id); },
			};
		}
	}

	function renamer(text: string): [Editor, Fake, Renamer, string[]] {
		const e = new Editor(new Document(text));
		const fake = new Fake();
		const notes: string[] = [];
		return [e, fake, new Renamer(e, fake.provider(), (m: string): void => { notes.push(m); }, (): void => {}), notes];
	}

	test "a rename opens on the word, applies the server's edits as one undo step and leaves the cursor after the new name" {
		const [e, fake, r, notes] = renamer("let ab = 1;\nab += ab;\n");
		e.select(single(13));
		r.start();
		const at = r.renaming() as Renaming;
		assert at.from == 12 && at.to == 14 && at.old == "ab" && at.selectFrom == 0 && at.selectTo == 2;
		r.confirm("total");
		assert r.renaming() === null && fake.renames.length == 1 && fake.renames[0][0] == 12 && fake.renames[0][1] == "total";
		fake.renameAnswers[0]([{ from: 4, to: 6, text: "total" }, { from: 12, to: 14, text: "total" }, { from: 18, to: 20, text: "total" }], 0, null);
		assert e.doc.text() == "let total = 1;\ntotal += total;\n" && notes.length == 0;
		assert e.selections.primaryRange().head == 20;
		e.undo();
		assert e.doc.text() == "let ab = 1;\nab += ab;\n";
	}

	test "a prepared rename opens where the server says, with the selection kept inside the name" {
		const [e, fake, r, notes] = renamer("let abc = 1;");
		fake.prepared = true;
		e.select({ ranges: [span(5, 6)], primary: 0 });
		r.start();
		assert r.renaming() === null && fake.prepares[0] == 6;
		fake.prepareAnswers[0]([4, 7], null);
		const at = r.renaming() as Renaming;
		assert at.old == "abc" && at.selectFrom == 1 && at.selectTo == 2;
		r.cancel();
		r.start();
		fake.prepareAnswers[1](null, null);
		assert r.renaming() === null && notes[0] == "nothing to rename here";
	}

	test "an empty or unchanged name, a failure or no word end the rename without a change, and other files changed are told" {
		const [e, fake, r, notes] = renamer("ab + ab");
		e.select(single(1));
		r.start();
		r.confirm("  ");
		r.start();
		r.confirm("ab");
		assert fake.renames.length == 0;
		r.start();
		r.confirm("cd");
		fake.renameAnswers[0]([], 2, null);
		assert e.doc.text() == "ab + ab" && notes[0] == "rename also changed 2 other files, not saved yet";
		r.start();
		r.confirm("cd");
		fake.renameAnswers[1](null, 0, "not a symbol");
		assert notes[1] == "rename failed: not a symbol";
		e.select(single(3));
		r.start();
		assert r.renaming() === null && notes[2] == "nothing to rename here";
	}
}
