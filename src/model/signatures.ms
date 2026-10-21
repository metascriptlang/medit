import { Anchor, Bias, Document } from "./document";
import { Editor } from "./editor";
import { isEmpty } from "./selection";
import { BracketPair, enclosingBrackets } from "./brackets";

export const SIGNATURE_DELAY_MS: int32 = 300;

export struct Parameter {
	from: int32;
	to: int32;
	documentation: string;
}

export struct Signature {
	label: string;
	documentation: string;
	parameters: Parameter[];
	active: int32;
}

export struct SignatureHelp {
	signatures: Signature[];
	active: int32;
	raw: string;
}

export enum SignatureTrigger {
	Invoked = 1,
	Character = 2,
	ContentChange = 3,
}

export struct SignatureAsk {
	offset: int32;
	trigger: SignatureTrigger;
	character: string | null;
	shown: SignatureHelp | null;
}

export interface SignatureProvider {
	ask: (question: SignatureAsk, done: (help: SignatureHelp | null) => void) => int32;
	cancel: (id: int32) => void;
	wait: (ms: int32, run: () => void) => int32;
	stopWaiting: (timer: int32) => void;
	busy: () => boolean;
	triggers: () => string[];
}

enum Hidden {
	Not,
	AutoClose,
	Escape,
	Selection,
}

// The innermost bracket pair whose inside holds the offset: after its opener, up to its closer.
export function bracketsAround(doc: Document, offset: int32): BracketPair | null {
	if (offset <= 0 || offset >= doc.length()) { return null; }
	return doc.enclosingBrackets(offset - 1, offset + 1);
}

function samePair(a: BracketPair | null, b: BracketPair | null): boolean {
	return a !== null && b !== null && (a as BracketPair).open == (b as BracketPair).open && (a as BracketPair).close == (b as BracketPair).close;
}

// Signature help follows the primary cursor: entering a bracket pair asks for it, moving to
// another pair or editing inside the shown one asks again, and leaving every pair, selecting
// text or Escape hides it until the cursor enters a pair again.
export class SignatureHelper {
	help: SignatureHelp | null = null;
	current: int32 = 0;
	private editor: Editor;
	private provider: SignatureProvider;
	private changed: () => void;
	private last: Anchor | null = null;
	private hidden: Hidden = Hidden.Not;
	private seq: int32 = 0;
	private asked: int32 = -1;
	private timer: int32 = -1;

	constructor(editor: Editor, provider: SignatureProvider, changed: () => void) {
		this.editor = editor;
		this.provider = provider;
		this.changed = changed;
		this.last = editor.doc.anchor(editor.selections.primaryRange().head, Bias.Left);
	}

	shown(): boolean { return this.help !== null; }

	signature(): Signature | null { return this.help === null ? null : (this.help as SignatureHelp).signatures[this.current]; }

	// After a command or typed text: `typed` is the text typed, or null for a command.
	moved(typed: string | null): void {
		const doc = this.editor.doc;
		const r = this.editor.selections.primaryRange();
		const old = this.last === null ? r.head : doc.resolve(this.last as Anchor);
		if (this.last !== null) { doc.release(this.last as Anchor); }
		this.last = doc.anchor(r.head, Bias.Left);
		if (!r.isEmpty()) {
			this.hide(Hidden.Selection);
			return;
		}
		const was = bracketsAround(doc, old);
		const now = bracketsAround(doc, r.head);
		if (now === null) {
			this.hide(Hidden.AutoClose);
			return;
		}
		if (samePair(was, now) && !this.shown() && this.hidden != Hidden.Selection) {
			this.hide(Hidden.AutoClose);
			return;
		}
		const opened = typed !== null && (typed == "(" || typed == "[" || typed == "{");
		const character = typed !== null && this.provider.triggers().includes(typed as string);
		this.ask(opened ? 0 : SIGNATURE_DELAY_MS, character ? SignatureTrigger.Character : SignatureTrigger.ContentChange, typed);
	}

	invoke(): void { this.ask(0, SignatureTrigger.Invoked, null); }

	private ask(delay: int32, trigger: SignatureTrigger, character: string | null): void {
		if (this.provider.busy()) { return; }
		this.stop();
		this.seq += 1;
		const seq = this.seq;
		const go = (): void => {
			this.timer = -1;
			if (this.provider.busy()) { return; }
			const question: SignatureAsk = {
				offset: this.editor.selections.primaryRange().head,
				trigger,
				character: trigger == SignatureTrigger.Character ? character : null,
				shown: this.help === null ? null : { ...(this.help as SignatureHelp), active: this.current },
			};
			this.asked = this.provider.ask(question, (help: SignatureHelp | null): void => {
				if (seq != this.seq) { return; }
				this.asked = -1;
				this.answered(help);
			});
		};
		if (delay > 0) { this.timer = this.provider.wait(delay, go); }
		else { go(); }
	}

	private answered(help: SignatureHelp | null): void {
		if (help === null || (help as SignatureHelp).signatures.length == 0) {
			this.hide(Hidden.AutoClose);
			return;
		}
		const h = help as SignatureHelp;
		this.help = h;
		this.current = Math.max(0, Math.min(h.active, (h.signatures.length as int32) - 1));
		this.hidden = Hidden.Not;
		this.changed();
	}

	private stop(): void {
		if (this.timer >= 0) { this.provider.stopWaiting(this.timer); }
		this.timer = -1;
		if (this.asked >= 0) { this.provider.cancel(this.asked); }
		this.asked = -1;
	}

	private hide(by: Hidden): void {
		this.stop();
		this.seq += 1;
		this.hidden = by;
		if (this.help === null) { return; }
		this.help = null;
		this.current = 0;
		this.changed();
	}

	// Escape and scrolling: hidden until the cursor enters another pair.
	dismiss(): void { this.hide(Hidden.Escape); }

	cycle(forward: boolean): void {
		if (this.help === null) { return; }
		const n = (this.help as SignatureHelp).signatures.length as int32;
		this.current = forward ? (this.current + 1) % n : (this.current + n - 1) % n;
		this.changed();
	}
}

when (testBuild) {
	import { single, span } from "./selection";
	import { typeText } from "./pairs";

	struct Asked {
		question: SignatureAsk;
		done: (help: SignatureHelp | null) => void;
	}

	class Fake {
		asks: Asked[] = [];
		waits: (() => void)[] = [];
		cancelled: int32 = 0;
		stopped: int32 = 0;
		busy: boolean = false;
	}

	function made(text: string, cursor: int32): [Editor, Fake, SignatureHelper] {
		const e = new Editor(new Document(text));
		e.select(single(cursor));
		const fake = new Fake();
		const provider: SignatureProvider = {
			ask: (question: SignatureAsk, done: (help: SignatureHelp | null) => void): int32 => {
				fake.asks.push({ question, done });
				return fake.asks.length as int32;
			},
			cancel: (id: int32): void => { fake.cancelled += 1; },
			wait: (ms: int32, run: () => void): int32 => {
				fake.waits.push(run);
				return fake.waits.length as int32;
			},
			stopWaiting: (timer: int32): void => { fake.stopped += 1; },
			busy: (): boolean => fake.busy,
			triggers: (): string[] => ["(", ","],
		};
		return [e, fake, new SignatureHelper(e, provider, (): void => {})];
	}

	function help(labels: string[]): SignatureHelp {
		const signatures: Signature[] = [];
		for (const label of labels) { signatures.push({ label, documentation: "", parameters: [], active: 0 }); }
		return { signatures, active: 0, raw: "[]" };
	}

	function typed(e: Editor, h: SignatureHelper, text: string): void {
		typeText(e, text);
		h.moved(text);
	}

	function moved(e: Editor, h: SignatureHelper, at: int32): void {
		e.select(single(at));
		h.moved(null);
	}

	test "typing an opener asks at once, typing inside the shown pair asks again after a pause, and leaving every pair hides" {
		const [e, fake, h] = made("f", 1);
		typed(e, h, "(");
		assert e.doc.slice(0, e.doc.length()) == "f()";
		assert fake.asks.length == 1 && fake.waits.length == 0;
		assert fake.asks[0].question.trigger == SignatureTrigger.Character && fake.asks[0].question.character == "(";
		assert fake.asks[0].question.shown === null;
		fake.asks[0].done(help(["f(a: int32, b: int32): void"]));
		assert h.shown();
		typed(e, h, "1");
		assert fake.asks.length == 1 && fake.waits.length == 1;
		fake.waits[0]();
		assert fake.asks.length == 2 && fake.asks[1].question.trigger == SignatureTrigger.ContentChange;
		assert fake.asks[1].question.shown !== null;
		typed(e, h, ",");
		fake.waits[1]();
		assert fake.asks[2].question.trigger == SignatureTrigger.Character && fake.asks[2].question.character == ",";
		assert fake.cancelled == 1;
		moved(e, h, 0);
		assert !h.shown() && fake.cancelled == 2;
	}

	test "Escape keeps it hidden inside the same pair until the cursor enters another" {
		const [e, fake, h] = made("f(a, g(b))", 3);
		h.invoke();
		assert fake.asks.length == 1 && fake.asks[0].question.trigger == SignatureTrigger.Invoked;
		fake.asks[0].done(help(["f"]));
		h.dismiss();
		assert !h.shown();
		moved(e, h, 4);
		assert fake.waits.length == 0 && !h.shown();
		moved(e, h, 7);
		assert fake.waits.length == 1;
		moved(e, h, 10);
		assert fake.stopped == 1;
	}

	test "a selection hides it, and a cursor back in the same pair asks again" {
		const [e, fake, h] = made("f(ab)", 3);
		h.invoke();
		fake.asks[0].done(help(["f"]));
		e.select({ ranges: [span(2, 4)], primary: 0 });
		h.moved(null);
		assert !h.shown();
		moved(e, h, 3);
		assert fake.waits.length == 1;
	}

	test "an older answer is dropped, an empty one hides, a busy menu asks nothing, and cycling wraps" {
		const [e, fake, h] = made("f(ab)", 3);
		h.invoke();
		h.invoke();
		fake.asks[0].done(help(["old"]));
		assert !h.shown();
		fake.asks[1].done(help(["one", "two", "three"]));
		assert h.shown() && (h.signature() as Signature).label == "one";
		h.cycle(false);
		assert (h.signature() as Signature).label == "three";
		h.cycle(true);
		assert (h.signature() as Signature).label == "one";
		h.invoke();
		fake.asks[2].done(null);
		assert !h.shown();
		fake.busy = true;
		h.invoke();
		assert fake.asks.length == 3;
	}
}
