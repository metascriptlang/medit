import { Anchor, Bias, Document } from "./document";
import { Editor } from "./editor";
import { wordAround } from "./completion";
import { primaryRange } from "./selection";

export const OCCURRENCE_DELAY_MS: int32 = 75;

export struct Occurrence {
	from: int32;
	to: int32;
	write: boolean;
}

export interface OccurrenceProvider {
	ask: (offset: int32, done: (found: Occurrence[] | null) => void) => int32;
	cancel: (id: int32) => void;
	wait: (ms: int32, run: () => void) => int32;
	stopWaiting: (timer: int32) => void;
}

struct Held {
	from: Anchor;
	to: Anchor;
	write: boolean;
}

// The places the server names for the symbol under the primary cursor, each read or written.
// They are asked once the cursor rests for OCCURRENCE_DELAY_MS and replace the shown ones when
// the answer comes, so the marks do not flicker while the cursor moves through one symbol; a
// selection whose ends lie in different words clears them at once, and a failed ask keeps them.
export class Occurrences {
	private editor: Editor;
	private provider: OccurrenceProvider;
	private changed: () => void;
	private held: Held[] = [];
	private seq: int32 = 0;
	private asked: int32 = -1;
	private timer: int32 = -1;

	constructor(editor: Editor, provider: OccurrenceProvider, changed: () => void) {
		this.editor = editor;
		this.provider = provider;
		this.changed = changed;
	}

	moved(): void {
		const doc = this.editor.doc;
		const r = this.editor.selections.primaryRange();
		const [headFrom, headTo] = wordAround(doc, r.head);
		const [tailFrom, tailTo] = wordAround(doc, r.anchor);
		this.stop();
		if (headFrom != tailFrom || headTo != tailTo) {
			this.replace([]);
			return;
		}
		const seq = this.seq;
		const at = r.head;
		this.timer = this.provider.wait(OCCURRENCE_DELAY_MS, (): void => {
			this.timer = -1;
			this.asked = this.provider.ask(at, (found: Occurrence[] | null): void => {
				if (seq != this.seq) { return; }
				this.asked = -1;
				if (found !== null) { this.replace(found as Occurrence[]); }
			});
		});
	}

	// The shown occurrences that touch from..to, offsets as the document is now.
	within(from: int32, to: int32): Occurrence[] {
		const doc = this.editor.doc;
		const out: Occurrence[] = [];
		for (const h of this.held) {
			const a = doc.resolve(h.from);
			const b = Math.max(a, doc.resolve(h.to));
			if (b >= from && a <= to) { out.push({ from: a, to: b, write: h.write }); }
		}
		return out;
	}

	count(): int32 { return this.held.length as int32; }

	private stop(): void {
		if (this.timer >= 0) { this.provider.stopWaiting(this.timer); }
		this.timer = -1;
		if (this.asked >= 0) { this.provider.cancel(this.asked); }
		this.asked = -1;
		this.seq += 1;
	}

	private replace(found: Occurrence[]): void {
		if (this.held.length == 0 && found.length == 0) { return; }
		const doc = this.editor.doc;
		for (const h of this.held) {
			doc.release(h.from);
			doc.release(h.to);
		}
		this.held = [];
		for (const o of found) {
			const from = Math.max(0, Math.min(o.from, doc.length()));
			const to = Math.max(from, Math.min(o.to, doc.length()));
			this.held.push({ from: doc.anchor(from, Bias.Right), to: doc.anchor(to, Bias.Left), write: o.write });
		}
		this.changed();
	}
}

when (testBuild) {
	import { single, span } from "./selection";

	class Fake {
		asks: int32[] = [];
		answers: Array<(found: Occurrence[] | null) => void> = [];
		cancelled: int32[] = [];
		timers: Array<() => void> = [];
		stopped: int32[] = [];

		provider(): OccurrenceProvider {
			return {
				ask: (offset: int32, done: (found: Occurrence[] | null) => void): int32 => {
					this.asks.push(offset);
					this.answers.push(done);
					return this.answers.length as int32;
				},
				cancel: (id: int32): void => { this.cancelled.push(id); },
				wait: (ms: int32, run: () => void): int32 => {
					this.timers.push(run);
					return (this.timers.length as int32) - 1;
				},
				stopWaiting: (timer: int32): void => { this.stopped.push(timer); },
			};
		}
	}

	function watching(text: string): [Editor, Fake, Occurrences, int32[]] {
		const e = new Editor(new Document(text));
		const fake = new Fake();
		const changes: int32[] = [0];
		return [e, fake, new Occurrences(e, fake.provider(), (): void => { changes[0] += 1; }), changes];
	}

	test "occurrences are asked once the cursor rests and follow later edits" {
		const [e, fake, o, changes] = watching("let ab = 1;\nab = ab + 1;\n");
		e.select(single(5));
		o.moved();
		assert fake.asks.length == 0 && fake.timers.length == 1;
		fake.timers[0]();
		assert fake.asks.length == 1 && fake.asks[0] == 5;
		fake.answers[0]([{ from: 4, to: 6, write: true }, { from: 12, to: 14, write: true }, { from: 17, to: 19, write: false }]);
		assert o.count() == 3 && changes[0] == 1;
		e.begin();
		const _c = e.change([{ from: 0, to: 0, text: "  " }]);
		e.end();
		const shown = o.within(0, 100);
		assert shown.length == 3 && shown[2].from == 19 && shown[2].to == 21 && !shown[2].write;
		assert o.within(0, 5).length == 0 && o.within(6, 6).length == 1;
	}

	test "a selection across words clears at once, a stale or failed answer changes nothing, an empty one clears" {
		const [e, fake, o, changes] = watching("ab cd ab");
		e.select(single(1));
		o.moved();
		fake.timers[0]();
		fake.answers[0]([{ from: 0, to: 2, write: false }, { from: 6, to: 8, write: false }]);
		e.select(single(4));
		o.moved();
		fake.timers[1]();
		e.select(single(7));
		o.moved();
		assert fake.cancelled.length == 1 && fake.cancelled[0] == 2;
		fake.answers[1]([]);
		assert o.count() == 2;
		fake.timers[2]();
		fake.answers[2](null);
		assert o.count() == 2 && changes[0] == 1;
		e.select({ ranges: [span(1, 4)], primary: 0 });
		o.moved();
		assert o.count() == 0 && changes[0] == 2 && fake.timers.length == 3;
		e.select(single(1));
		o.moved();
		fake.timers[3]();
		fake.answers[3]([]);
		assert o.count() == 0 && changes[0] == 2;
	}
}
