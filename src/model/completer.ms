import { Anchor, Bias } from "./document";
import { Editor } from "./editor";
import { start } from "./selection";
import { isWordByte } from "./motion";
import { Choice, Completion, accept, acceptLater, bufferWords, queryAt, ranked } from "./completion";
import { charsOf } from "../text/fuzzy";

export enum MenuMove {
	Previous,
	Next,
	First,
	Last,
}

export interface Provider {
	ask: (offset: int32, trigger: string | null, done: (items: Completion[], incomplete: boolean) => void) => int32;
	resolve: (item: Completion, done: (resolved: Completion) => void) => boolean;
	cancel: (id: int32) => void;
	triggers: () => string[];
}

// The completion menu's state. `update` asks the provider for completions at the cursor, or
// filters the ones it holds while the query only grows from where they were asked; the menu
// stays open while the cursor stays at the end of the word it completes. Questions run side by
// side: an answer cancels the older ones still out and is dropped when a newer one is shown.
export class Completer {
	items: Completion[] = [];
	choices: Choice[] = [];
	selected: int32 = 0;
	private editor: Editor;
	private provider: Provider;
	private changed: () => void;
	private open: boolean = false;
	private at: Anchor | null = null;
	private initialQuery: string | null = null;
	private incomplete: boolean = false;
	private live: Set<int32> = new Set<int32>();
	private asks: Map<int32, int32> = new Map<int32, int32>();
	private shownSeq: int32 = -1;
	private seq: int32 = 0;
	private accepted: int32 = 0;

	constructor(editor: Editor, provider: Provider, changed: () => void) {
		this.editor = editor;
		this.provider = provider;
		this.changed = changed;
	}

	shown(): boolean { return this.open && this.choices.length > 0; }

	selectedItem(): Completion | null {
		return this.shown() ? this.items[this.choices[this.selected].index] : null;
	}

	private head(): int32 { return this.editor.selections.primaryRange().head; }

	private filter(query: string): void {
		this.choices = ranked(this.items, query);
		this.selected = 0;
		this.resolveSelected();
	}

	private isTrigger(text: string): boolean {
		if (charsOf(text).text.length != 1) { return false; }
		return isWordByte(text.byteAt(0)) || this.provider.triggers().includes(text);
	}

	update(trigger: string | null): void {
		const doc = this.editor.doc;
		const head = this.head();
		const query = queryAt(doc, head);
		if (query === null && this.open) { this.hide(); }
		if (this.open) {
			this.filter(query === null ? "" : query as string);
			const grows = this.initialQuery === null || (query !== null && (query as string).startsWith(this.initialQuery as string));
			if (!this.incomplete && grows && doc.resolve(this.at as Anchor) == head) {
				this.changed();
				return;
			}
		}
		if (trigger !== null && !this.isTrigger(trigger as string)) {
			this.hide();
			this.changed();
			return;
		}
		this.seq += 1;
		const seq = this.seq;
		const at = doc.anchor(head, Bias.Right);
		const sent = trigger !== null && this.provider.triggers().includes(trigger as string) ? trigger : null;
		this.live.add(seq);
		const id = this.provider.ask(head, sent, (items: Completion[], incomplete: boolean): void => {
			this.answered(seq, at, query, items, incomplete);
		});
		if (id < 0) { this.answered(seq, at, query, [], false); }
		else if (this.live.has(seq)) { this.asks.set(seq, id); }
	}

	private answered(seq: int32, at: Anchor, query: string | null, items: Completion[], incomplete: boolean): void {
		const doc = this.editor.doc;
		if (!this.live.has(seq)) {
			doc.release(at);
			return;
		}
		this.settle(seq);
		if (this.open && this.shownSeq > seq) {
			doc.release(at);
			return;
		}
		const found = items.length > 0 ? items : bufferWords(doc, this.head());
		if (found.length == 0) {
			doc.release(at);
			if (this.live.size == 0) { this.close(); }
			this.changed();
			return;
		}
		this.close();
		this.items = found;
		this.at = at;
		this.initialQuery = query;
		this.incomplete = incomplete;
		this.open = true;
		this.shownSeq = seq;
		const now = queryAt(doc, this.head());
		this.filter(now === null ? "" : now as string);
		if (!this.shown()) { this.close(); }
		this.changed();
	}

	typed(text: string): void { this.update(text.byteLength > 0 ? text : null); }

	// After a command moved the cursors or edited: keep the menu while the primary cursor is
	// where the menu's word ends and a word byte is before it, else close it.
	moved(): void {
		if (!this.open) { return; }
		const doc = this.editor.doc;
		const at = this.editor.selections.primaryRange().start();
		const keep = doc.resolve(this.at as Anchor) == at && at > 0 && isWordByte(doc.byteAt(at - 1));
		if (keep) { this.update(null); }
		else {
			this.hide();
			this.changed();
		}
	}

	private settle(seq: int32): void {
		const older: int32[] = [];
		for (const s of this.live) {
			if (s <= seq) { older.push(s); }
		}
		for (const s of older) {
			const id = this.asks.get(s);
			if (s < seq && id !== undefined) { this.provider.cancel(id as int32); }
			this.asks.delete(s);
			this.live.delete(s);
		}
	}

	hide(): void {
		for (const [s, id] of this.asks) { this.provider.cancel(id); }
		this.asks.clear();
		this.live.clear();
		this.close();
	}

	private close(): void {
		if (this.at !== null) { this.editor.doc.release(this.at as Anchor); }
		this.at = null;
		this.open = false;
		this.items = [];
		this.choices = [];
		this.selected = 0;
		this.initialQuery = null;
		this.incomplete = false;
	}

	move(m: MenuMove): void {
		const n = this.choices.length as int32;
		if (n == 0) { return; }
		const next = match (m) {
			MenuMove.Previous => this.selected > 0 ? this.selected - 1 : n - 1,
			MenuMove.Next => this.selected + 1 < n ? this.selected + 1 : 0,
			MenuMove.First => 0,
			MenuMove.Last => n - 1,
		};
		if (next != this.selected) {
			this.selected = next;
			this.resolveSelected();
		}
		this.changed();
	}

	pick(choice: int32): void {
		if (choice < 0 || choice >= (this.choices.length as int32)) { return; }
		this.selected = choice;
		this.resolveSelected();
	}

	private resolveSelected(): void {
		const item = this.selectedItem();
		if (item === null || (item as Completion).resolved) { return; }
		const index = this.choices[this.selected].index;
		const items = this.items;
		const _asked = this.provider.resolve(item as Completion, (resolved: Completion): void => {
			if (this.items !== items) { return; }
			this.items[index] = resolved;
			this.changed();
		});
	}

	// Accepts the selected completion; `replace` forces replacing or inserting before the word
	// after the cursor, null leaves it to the label. Returns the number of the server's extra
	// edits left out, or null when nothing was accepted.
	confirm(replace: boolean | null): int32 | null {
		const item = this.selectedItem();
		if (item === null) { return null; }
		const c = item as Completion;
		this.hide();
		this.accepted += 1;
		const group = `completion ${this.accepted}`;
		const skipped = accept(this.editor, c, replace, group);
		if (skipped === null || c.resolved) {
			this.changed();
			return skipped;
		}
		const editor = this.editor;
		const _asked = this.provider.resolve(c, (resolved: Completion): void => {
			const _late = acceptLater(editor, resolved.extra, resolved.extraAt, group);
			this.changed();
		});
		this.changed();
		return skipped;
	}
}

when (testBuild) {
	import { Document } from "./document";
	import { single } from "./selection";

	struct Asked {
		offset: int32;
		trigger: string | null;
		done: (items: Completion[], incomplete: boolean) => void;
	}

	class Fake {
		asks: Asked[] = [];
		resolves: int32 = 0;
		cancelled: int32 = 0;
		later: boolean = false;
		pending: Completion[] = [];
		answers: ((resolved: Completion) => void)[] = [];
	}

	function item(label: string, at: int32, from: int32, to: int32): Completion {
		return {
			label, detail: "", documentation: "", filterText: label, sortText: null, kind: 0, deprecated: false,
			newText: label, replaceFrom: from, replaceTo: to, insertTo: to, at, extra: [], extraAt: at,
			resolved: true, raw: "",
		};
	}

	function made(text: string, cursor: int32): [Editor, Fake, Completer] {
		const e = new Editor(new Document(text));
		e.select(single(cursor));
		const fake = new Fake();
		const provider: Provider = {
			ask: (offset: int32, trigger: string | null, done: (items: Completion[], incomplete: boolean) => void): int32 => {
				fake.asks.push({ offset, trigger, done });
				return fake.asks.length as int32;
			},
			resolve: (c: Completion, done: (resolved: Completion) => void): boolean => {
				fake.resolves += 1;
				if (fake.later) {
					fake.pending.push(c);
					fake.answers.push(done);
				} else { done({ ...c, resolved: true, documentation: "doc" }); }
				return true;
			},
			cancel: (id: int32): void => { fake.cancelled += 1; },
			triggers: (): string[] => ["."],
		};
		return [e, fake, new Completer(e, provider, (): void => {})];
	}

	function type(e: Editor, c: Completer, text: string): void {
		const head = e.selections.primaryRange().head;
		e.begin();
		const _a = e.change([{ from: head, to: head, text }]);
		e.select(single(head + (text.byteLength as int32)));
		e.end();
		c.typed(text);
	}

	test "a word byte asks once, and typing on filters the held completions" {
		const [e, fake, c] = made("", 0);
		type(e, c, "c");
		assert fake.asks.length == 1 && fake.asks[0].trigger === null;
		const v = e.doc.version();
		fake.asks[0].done([item("const", v, 0, 1), item("class", v, 0, 1), item("console", v, 0, 1)], false);
		assert c.shown() && c.choices.length == 3;
		type(e, c, "o");
		assert fake.asks.length == 1;
		assert c.choices.length == 2 && c.items[c.choices[0].index].label == "console";
		c.move(MenuMove.Next);
		assert c.selectedItem() !== null && (c.selectedItem() as Completion).label == "const";
		c.move(MenuMove.Next);
		assert (c.selectedItem() as Completion).label == "console";
		c.move(MenuMove.Previous);
		assert c.confirm(null) == 0;
		assert e.doc.slice(0, e.doc.length()) == "const" && !c.shown();
	}

	test "a trigger character asks with it, a query that stops matching hides the menu, and a cursor move closes it" {
		const [e, fake, c] = made("x", 1);
		type(e, c, ".");
		assert fake.asks.length == 1 && fake.asks[0].trigger == ".";
		const v = e.doc.version();
		fake.asks[0].done([item("log", v, 2, 2)], false);
		assert c.shown();
		type(e, c, "q");
		assert !c.shown() && fake.asks.length == 1;
		type(e, c, "r");
		assert fake.asks.length == 1;
		type(e, c, " ");
		type(e, c, "s");
		assert fake.asks.length == 2;
		e.select(single(0));
		c.moved();
		assert !c.shown();
	}

	test "an answer to an older question is dropped, and an incomplete list asks again" {
		const [e, fake, c] = made("", 0);
		type(e, c, "a");
		type(e, c, " ");
		type(e, c, "b");
		const v = e.doc.version();
		fake.asks[0].done([item("abc", v, 0, 1)], false);
		assert !c.shown();
		fake.asks[1].done([item("bar", v, 2, 3)], true);
		assert c.shown();
		type(e, c, "a");
		assert fake.asks.length == 3;
	}

	test "questions run side by side: an older answer shows until a newer one lands, then comes too late" {
		const [e, fake, c] = made("", 0);
		type(e, c, "c");
		type(e, c, "o");
		assert fake.asks.length == 2 && fake.cancelled == 0;
		const v = e.doc.version();
		fake.asks[0].done([item("cold", v, 0, 2), item("coat", v, 0, 2)], false);
		assert c.shown() && c.choices.length == 2;
		fake.asks[1].done([item("const", v, 0, 2), item("coxa", v, 0, 2), item("coxy", v, 0, 2)], true);
		assert c.choices.length == 3;
		type(e, c, "x");
		type(e, c, "y");
		assert fake.asks.length == 4;
		fake.asks[3].done([item("coxy", v, 0, 4)], false);
		assert c.choices.length == 1;
		assert fake.cancelled == 1 && (c.selectedItem() as Completion).label == "coxy";
		fake.asks[2].done([item("coxa", v, 0, 3)], false);
		assert (c.selectedItem() as Completion).label == "coxy";
	}

	test "with no completions from the provider, words of the text complete one of three characters" {
		const [e, fake, c] = made("console.log(count, 2co);\n", 25);
		type(e, c, "c");
		type(e, c, "o");
		fake.asks[0].done([], false);
		fake.asks[1].done([], false);
		assert !c.shown();
		type(e, c, "n");
		fake.asks[2].done([], false);
		assert c.shown() && c.choices.length == 2;
		assert (c.selectedItem() as Completion).label == "console";
		assert c.confirm(null) == 0;
		assert e.doc.slice(25, e.doc.length()) == "console";
	}

	test "a resolve that answers after a newer list replaced the menu leaves the new list alone" {
		const [e, fake, c] = made("", 0);
		fake.later = true;
		type(e, c, "a");
		type(e, c, "b");
		const v = e.doc.version();
		const unresolved = (label: string): Completion => ({ ...item(label, v, 0, 2), resolved: false });
		fake.asks[0].done([unresolved("xx"), unresolved("yy"), unresolved("zz"), unresolved("ab"), unresolved("abc")], false);
		c.move(MenuMove.Next);
		assert fake.pending.length == 2 && fake.pending[1].label == "abc";
		fake.asks[1].done([unresolved("ab"), unresolved("abd"), unresolved("abe")], false);
		assert c.items.length == 3;
		fake.answers[1]({ ...fake.pending[1], resolved: true, documentation: "late" });
		assert c.items.length == 3 && c.items.filter((i) => i.documentation != "").length == 0;
	}
}
