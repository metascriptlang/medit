import { Anchor, Bias, Document } from "./document";

export const EDIT_DELAY_MS: int32 = 700;
export const SCROLL_DELAY_MS: int32 = 50;

export struct Inlay {
	at: int32;
	text: string;
	bias: Bias;
}

export interface InlayProvider {
	ask: (from: int32, to: int32, done: (found: Inlay[] | null) => void) => int32;
	cancel: (id: int32) => void;
	wait: (ms: int32, run: () => void) => int32;
	stopWaiting: (timer: int32) => void;
}

struct Held {
	at: Anchor;
	text: string;
	bias: Bias;
}

function inOrder(a: Inlay, b: Inlay): number {
	if (a.at != b.at) { return a.at - b.at; }
	return (a.bias as int32) - (b.bias as int32);
}

// The hints the server gives for the shown text and as many lines above and below it, off until
// toggled. They are asked again once an edit rests for EDIT_DELAY_MS or a scroll past the asked
// lines rests for SCROLL_DELAY_MS; until then the held ones follow the edits.
export class InlayHints {
	private doc: Document;
	private provider: InlayProvider;
	private told: (message: string) => void;
	private changed: () => void;
	private on: boolean = false;
	private held: Held[] = [];
	private shownFrom: int32 = 0;
	private shownTo: int32 = 0;
	private askedAt: int32 = -1;
	private askedFrom: int32 = 0;
	private askedTo: int32 = 0;
	private plannedAt: int32 = -1;
	private plannedFrom: int32 = 0;
	private plannedTo: int32 = 0;
	private seq: int32 = 0;
	private asked: int32 = -1;
	private timer: int32 = -1;

	constructor(doc: Document, provider: InlayProvider, told: (message: string) => void, changed: () => void) {
		this.doc = doc;
		this.provider = provider;
		this.told = told;
		this.changed = changed;
	}

	enabled(): boolean { return this.on; }

	toggle(): void {
		this.stop();
		this.askedAt = -1;
		this.on = !this.on;
		if (!this.on) {
			this.replace([]);
			return;
		}
		if (!this.fetch()) {
			this.on = false;
			this.told("no language server offers inlay hints in this file");
		}
	}

	visible(from: int32, to: int32): void {
		this.shownFrom = from;
		this.shownTo = to;
		if (!this.on) { return; }
		const version = this.doc.version();
		const edited = version != this.askedAt;
		if (!edited && from >= this.askedFrom && to <= this.askedTo) { return; }
		if (this.timer >= 0 && version == this.plannedAt && from == this.plannedFrom && to == this.plannedTo) { return; }
		this.stop();
		this.plannedAt = version;
		this.plannedFrom = from;
		this.plannedTo = to;
		this.timer = this.provider.wait(edited ? EDIT_DELAY_MS : SCROLL_DELAY_MS, (): void => {
			this.timer = -1;
			if (!this.fetch()) { this.askedAt = -1; }
		});
	}

	within(from: int32, to: int32): Inlay[] {
		const out: Inlay[] = [];
		for (const h of this.held) {
			const at = this.doc.resolve(h.at);
			if (at >= from && at <= to) { out.push({ at, text: h.text, bias: h.bias }); }
		}
		out.sort(inOrder);
		return out;
	}

	count(): int32 { return this.held.length as int32; }

	private fetch(): boolean {
		const doc = this.doc;
		const top = doc.lineOf(this.shownFrom);
		const bottom = doc.lineOf(this.shownTo);
		const margin = bottom - top + 1;
		const from = doc.lineStart(Math.max(0, top - margin));
		const to = doc.lineEnd(Math.min(doc.lineCount() - 1, bottom + margin));
		this.askedAt = doc.version();
		this.askedFrom = from;
		this.askedTo = to;
		const seq = this.seq;
		const id = this.provider.ask(from, to, (found: Inlay[] | null): void => {
			if (seq != this.seq) { return; }
			this.asked = -1;
			if (found !== null) { this.replace(found as Inlay[]); }
		});
		if (id < 0) { return false; }
		if (seq == this.seq) { this.asked = id; }
		return true;
	}

	private stop(): void {
		if (this.timer >= 0) { this.provider.stopWaiting(this.timer); }
		this.timer = -1;
		if (this.asked >= 0) { this.provider.cancel(this.asked); }
		this.asked = -1;
		this.seq += 1;
	}

	private replace(found: Inlay[]): void {
		if (this.held.length == 0 && found.length == 0) { return; }
		const doc = this.doc;
		for (const h of this.held) { doc.release(h.at); }
		this.held = [];
		for (const i of found) {
			const at = Math.max(0, Math.min(i.at, doc.length()));
			this.held.push({ at: doc.anchor(at, i.bias), text: i.text, bias: i.bias });
		}
		this.changed();
	}
}

when (testBuild) {
	class Fake {
		asks: Array<[int32, int32]> = [];
		answers: Array<(found: Inlay[] | null) => void> = [];
		cancelled: int32[] = [];
		delays: int32[] = [];
		timers: Array<() => void> = [];
		stopped: int32[] = [];
		refuse: boolean = false;

		provider(): InlayProvider {
			return {
				ask: (from: int32, to: int32, done: (found: Inlay[] | null) => void): int32 => {
					if (this.refuse) { return -1; }
					this.asks.push([from, to]);
					this.answers.push(done);
					return this.answers.length as int32;
				},
				cancel: (id: int32): void => { this.cancelled.push(id); },
				wait: (ms: int32, run: () => void): int32 => {
					this.delays.push(ms);
					this.timers.push(run);
					return (this.timers.length as int32) - 1;
				},
				stopWaiting: (timer: int32): void => { this.stopped.push(timer); },
			};
		}
	}

	function hinting(text: string): [Document, Fake, InlayHints, string[], int32[]] {
		const d = new Document(text);
		const fake = new Fake();
		const notes: string[] = [];
		const changes: int32[] = [0];
		const hints = new InlayHints(d, fake.provider(), (m: string): void => { notes.push(m); }, (): void => { changes[0] += 1; });
		return [d, fake, hints, notes, changes];
	}

	function lines(n: int32): string {
		let text = "";
		for (let k = 0; k < n; k++) { text += `line ${k}\n`; }
		return text;
	}

	test "hints are off until toggled, then asked at once for the shown lines and as many on each side" {
		const [d, fake, hints, notes, changes] = hinting(lines(20));
		hints.visible(d.lineStart(8), d.lineEnd(9));
		assert fake.asks.length == 0 && fake.timers.length == 0 && !hints.enabled();
		hints.toggle();
		assert hints.enabled() && fake.asks.length == 1;
		assert fake.asks[0][0] == d.lineStart(6) && fake.asks[0][1] == d.lineEnd(11);
		fake.answers[0]([{ at: d.lineStart(9), text: "b:", bias: Bias.Left }, { at: d.lineStart(8) + 4, text: ": int32", bias: Bias.Right }]);
		const shown = hints.within(0, d.length());
		assert changes[0] == 1 && shown.length == 2 && shown[0].text == ": int32" && shown[1].text == "b:";
		hints.toggle();
		assert !hints.enabled() && hints.count() == 0 && changes[0] == 2 && notes.length == 0;
	}

	test "an edit asks again once it rests, a scroll past the asked lines sooner, and a stale answer is dropped" {
		const [d, fake, hints, notes, changes] = hinting(lines(40));
		hints.visible(d.lineStart(10), d.lineEnd(11));
		hints.toggle();
		fake.answers[0]([{ at: d.lineStart(10) + 4, text: ": int32", bias: Bias.Right }]);
		hints.visible(d.lineStart(9), d.lineEnd(10));
		assert fake.timers.length == 0;
		const _e = d.splice({ from: d.lineStart(10), to: d.lineStart(10), text: "xx" });
		assert hints.within(0, d.length())[0].at == d.lineStart(10) + 6;
		hints.visible(d.lineStart(10), d.lineEnd(11));
		hints.visible(d.lineStart(10), d.lineEnd(11));
		assert fake.timers.length == 1 && fake.delays[0] == EDIT_DELAY_MS;
		const _f = d.splice({ from: 0, to: 0, text: "y" });
		hints.visible(d.lineStart(10), d.lineEnd(11));
		assert fake.timers.length == 2 && fake.stopped[0] == 0;
		fake.timers[1]();
		assert fake.asks.length == 2;
		hints.visible(d.lineStart(30), d.lineEnd(31));
		assert fake.delays[2] == SCROLL_DELAY_MS && fake.cancelled[0] == 2;
		fake.answers[1]([]);
		assert hints.count() == 1;
		fake.timers[2]();
		fake.answers[2](null);
		assert hints.count() == 1 && changes[0] == 1;
		hints.visible(d.lineStart(30), d.lineEnd(31));
		assert fake.timers.length == 3;
	}

	test "toggling on with no server that offers hints is told and leaves them off" {
		const [d, fake, hints, notes, changes] = hinting("let x = 1;\n");
		fake.refuse = true;
		hints.toggle();
		assert !hints.enabled() && notes[0] == "no language server offers inlay hints in this file";
	}
}
