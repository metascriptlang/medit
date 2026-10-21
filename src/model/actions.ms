import { Edit } from "./document";
import { Editor } from "./editor";
import { MenuMove } from "./completer";
import { acceptLater } from "./completion";
import { end, primaryRange, start } from "./selection";

// An action a language server offers for a range. `raw` is the server's own text of it, sent
// back to resolve or run it.
export struct CodeAction {
	title: string;
	kind: string;
	preferred: boolean;
	raw: string;
}

export interface ActionProvider {
	ask: (from: int32, to: int32, done: (found: CodeAction[] | null) => void) => int32;
	apply: (action: CodeAction, done: (edits: Edit[] | null, others: int32, error: string | null) => void) => int32;
	cancel: (id: int32) => void;
}

// The actions offered for the primary selection, listed in the server's order with the first
// selected. Confirming applies the selected one's edits to this document as one undo step; an
// action that also edits other documents is refused whole, as a rename is.
export class CodeActions {
	selected: int32 = 0;
	private editor: Editor;
	private provider: ActionProvider;
	private told: (message: string) => void;
	private changed: () => void;
	private listed: CodeAction[] = [];
	private asked: int32 = -1;
	private seq: int32 = 0;

	constructor(editor: Editor, provider: ActionProvider, told: (message: string) => void, changed: () => void) {
		this.editor = editor;
		this.provider = provider;
		this.told = told;
		this.changed = changed;
	}

	// Asks for the actions, or closes the list when it shows.
	toggle(): void {
		if (this.shown()) {
			this.close();
			return;
		}
		this.close();
		const seq = this.seq;
		const r = this.editor.selections.primaryRange();
		const id = this.provider.ask(r.start(), r.end(), (found: CodeAction[] | null): void => {
			if (seq != this.seq) { return; }
			this.asked = -1;
			if (found === null) { this.told("listing code actions failed"); }
			else if (found.length == 0) { this.told("no code actions here"); }
			else {
				this.listed = found as CodeAction[];
				this.selected = 0;
				this.changed();
			}
		});
		if (id < 0) { this.told("no language server offers code actions in this file"); }
		else { this.asked = id; }
	}

	shown(): boolean { return this.listed.length > 0; }

	actions(): CodeAction[] { return this.listed; }

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

	pick(index: int32): void {
		if (index < 0 || index >= (this.listed.length as int32)) { return; }
		this.selected = index;
		this.confirm();
	}

	confirm(): void {
		if (!this.shown()) { return; }
		const action = this.listed[this.selected];
		this.close();
		const seq = this.seq;
		let answered = false;
		const id = this.provider.apply(action, (edits: Edit[] | null, others: int32, error: string | null): void => {
			answered = true;
			if (seq != this.seq) { return; }
			this.asked = -1;
			if (error !== null) {
				this.told(`${action.title} failed: ${error as string}`);
				return;
			}
			if (others > 0) {
				this.told(`${action.title} refused: it also changes ${others} file${others == 1 ? " that is" : "s that are"} not open, and medic edits open files only`);
				return;
			}
			const skipped = acceptLater(this.editor, edits as Edit[], this.editor.doc.version(), "");
			if (skipped > 0) { this.told(`left out ${skipped} edit${skipped == 1 ? "" : "s"} of ${action.title} that overlap another`); }
		});
		if (id < 0) { this.told("no language server applies code actions in this file"); }
		else if (!answered) { this.asked = id; }
	}

	close(): void {
		if (this.asked >= 0) { this.provider.cancel(this.asked); }
		this.asked = -1;
		this.seq += 1;
		if (!this.shown()) { return; }
		this.listed = [];
		this.selected = 0;
		this.changed();
	}
}

when (testBuild) {
	import { Document } from "./document";
	import { single, span } from "./selection";

	class Fake {
		asks: Array<[int32, int32]> = [];
		answers: Array<(found: CodeAction[] | null) => void> = [];
		applied: string[] = [];
		results: Array<(edits: Edit[] | null, others: int32, error: string | null) => void> = [];
		cancelled: int32[] = [];

		provider(): ActionProvider {
			return {
				ask: (from: int32, to: int32, done: (found: CodeAction[] | null) => void): int32 => {
					this.asks.push([from, to]);
					this.answers.push(done);
					return this.answers.length as int32;
				},
				apply: (action: CodeAction, done: (edits: Edit[] | null, others: int32, error: string | null) => void): int32 => {
					this.applied.push(action.title);
					this.results.push(done);
					return 100 + (this.results.length as int32);
				},
				cancel: (id: int32): void => { this.cancelled.push(id); },
			};
		}
	}

	function acting(text: string): [Editor, Fake, CodeActions, string[]] {
		const e = new Editor(new Document(text));
		const fake = new Fake();
		const notes: string[] = [];
		return [e, fake, new CodeActions(e, fake.provider(), (m: string): void => { notes.push(m); }, (): void => {}), notes];
	}

	function action(title: string): CodeAction {
		return { title, kind: "quickfix", preferred: false, raw: "" };
	}

	test "the actions for the selection are listed, and the confirmed one's edits apply as one undo step" {
		const [e, fake, actions, notes] = acting("let  x = 1;  \n");
		e.select({ ranges: [span(6, 3)], primary: 0 });
		actions.toggle();
		assert fake.asks[0][0] == 3 && fake.asks[0][1] == 6 && !actions.shown();
		fake.answers[0]([action("Fix: Reformat this line"), action("Remove trailing whitespace")]);
		assert actions.shown() && actions.selected == 0;
		actions.move(MenuMove.Previous);
		assert actions.selected == 1;
		actions.move(MenuMove.Next);
		actions.confirm();
		assert !actions.shown() && fake.applied[0] == "Fix: Reformat this line";
		fake.results[0]([{ from: 0, to: 13, text: "let x = 1;" }], 0, null);
		assert e.doc.text() == "let x = 1;\n" && notes.length == 0;
		e.undo();
		assert e.doc.text() == "let  x = 1;  \n";
	}

	test "toggling closes the list, and nothing, a failure or edits to other files are told" {
		const [e, fake, actions, notes] = acting("abc\n");
		e.select(single(1));
		actions.toggle();
		fake.answers[0]([action("a")]);
		actions.toggle();
		assert !actions.shown() && fake.asks.length == 1;
		actions.toggle();
		fake.answers[1]([]);
		assert notes[0] == "no code actions here";
		actions.toggle();
		actions.close();
		fake.answers[2]([action("late")]);
		assert !actions.shown() && fake.cancelled[0] == 3;
		actions.toggle();
		fake.answers[3]([action("Import x")]);
		actions.pick(0);
		fake.results[0](null, 2, null);
		assert notes[1] == "Import x refused: it also changes 2 files that are not open, and medic edits open files only";
		assert e.doc.text() == "abc\n";
		actions.toggle();
		fake.answers[4]([action("Fix")]);
		actions.confirm();
		fake.results[1](null, 0, "no such command");
		assert notes[2] == "Fix failed: no such command";
	}
}
