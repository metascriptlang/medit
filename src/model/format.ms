import { Edit } from "./document";
import { Editor } from "./editor";
import { acceptLater, edited } from "./completion";
import { end, start } from "./selection";

export const FORMAT_TIMEOUT_MS: int32 = 5000;

export interface FormatProvider {
	format: (range: [int32, int32] | null, done: (edits: Edit[] | null, error: string | null) => void) => int32;
	cancel: (id: int32) => void;
	wait: (ms: int32, run: () => void) => int32;
	stopWaiting: (timer: int32) => void;
}

struct Answer {
	edits: Edit[];
	version: int32;
}

// Formats the whole document, or each selection, and applies every answer as one undo step
// once all have come. A newer format replaces one still waiting, and one that has not heard
// from all of its requests within FORMAT_TIMEOUT_MS is dropped.
export class Formatter {
	private editor: Editor;
	private provider: FormatProvider;
	private told: (message: string) => void;
	private asked: int32[] = [];
	private timer: int32 = -1;
	private seq: int32 = 0;

	constructor(editor: Editor, provider: FormatProvider, told: (message: string) => void) {
		this.editor = editor;
		this.provider = provider;
		this.told = told;
	}

	run(selections: boolean): void {
		this.stop();
		const seq = this.seq;
		const ranges: Array<[int32, int32] | null> = [];
		if (selections) {
			for (const s of this.editor.selections.ranges) { ranges.push([s.start(), s.end()]); }
		} else {
			ranges.push(null);
		}
		const answers: Answer[] = [];
		for (const r of ranges) {
			const id = this.provider.format(r, (edits: Edit[] | null, error: string | null): void => {
				if (seq != this.seq) { return; }
				if (error !== null) {
					this.stop();
					this.told(`formatting failed: ${error as string}`);
					return;
				}
				answers.push({ edits: edits as Edit[], version: this.editor.doc.version() });
				if (answers.length == ranges.length) {
					this.stop();
					this.apply(answers);
				}
			});
			if (id < 0) {
				this.stop();
				this.told(selections ? "no language server formats a selection of this file" : "no language server formats this file");
				return;
			}
			this.asked.push(id);
		}
		this.timer = this.provider.wait(FORMAT_TIMEOUT_MS, (): void => {
			this.timer = -1;
			this.stop();
			this.told("formatting timed out");
		});
	}

	private stop(): void {
		if (this.timer >= 0) { this.provider.stopWaiting(this.timer); }
		this.timer = -1;
		for (const id of this.asked) { this.provider.cancel(id); }
		this.asked = [];
		this.seq += 1;
	}

	private apply(answers: Answer[]): void {
		const doc = this.editor.doc;
		const now: Edit[] = [];
		let lost = 0;
		for (const a of answers) {
			for (const e of a.edits) {
				const m = edited(doc, a.version, e);
				if (m === null) { lost += 1; } else { now.push(m as Edit); }
			}
		}
		const skipped = lost + acceptLater(this.editor, now, doc.version(), "");
		if (skipped > 0) {
			this.told(`left out ${skipped} formatting edit${skipped == 1 ? "" : "s"} that overlap another or name text no longer kept`);
		}
	}
}

when (testBuild) {
	import { Document } from "./document";
	import { single } from "./selection";

	class Fake {
		asks: Array<[int32, int32] | null> = [];
		answers: Array<(edits: Edit[] | null, error: string | null) => void> = [];
		cancelled: int32[] = [];
		timers: Array<() => void> = [];
		stopped: int32[] = [];
		refuse: boolean = false;

		provider(): FormatProvider {
			return {
				format: (range: [int32, int32] | null, done: (edits: Edit[] | null, error: string | null) => void): int32 => {
					if (this.refuse) { return -1; }
					this.asks.push(range);
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

	function formatting(text: string): [Editor, Fake, Formatter, string[]] {
		const e = new Editor(new Document(text));
		const fake = new Fake();
		const notes: string[] = [];
		return [e, fake, new Formatter(e, fake.provider(), (m: string): void => { notes.push(m); }), notes];
	}

	test "a document format applies its answer as one undo step and keeps the cursor on its text" {
		const [e, fake, f, notes] = formatting("a  =1\nb=2\n");
		e.select(single(8));
		f.run(false);
		assert fake.asks.length == 1 && fake.asks[0] === null;
		fake.answers[0]([{ from: 1, to: 3, text: " " }, { from: 4, to: 4, text: " " }, { from: 7, to: 8, text: " = " }], null);
		assert e.doc.text() == "a = 1\nb = 2\n" && notes.length == 0;
		assert e.selections.primaryRange().head == 10 && fake.stopped.length == 1;
		e.undo();
		assert e.doc.text() == "a  =1\nb=2\n";
	}

	test "a selection format waits for every selection's answer, mapped through typing in between" {
		const [e, fake, f, notes] = formatting("a=1\nb=2\n");
		e.select({ ranges: [{ anchor: 0, head: 3 }, { anchor: 4, head: 7 }], primary: 0 });
		f.run(true);
		assert fake.asks.length == 2 && (fake.asks[1] as [int32, int32])[0] == 4;
		fake.answers[1]([{ from: 5, to: 6, text: " = " }], null);
		assert e.doc.text() == "a=1\nb=2\n";
		e.begin();
		const _c = e.change([{ from: 8, to: 8, text: "c" }]);
		e.end();
		fake.answers[0]([{ from: 1, to: 2, text: " = " }], null);
		assert e.doc.text() == "a = 1\nb = 2\nc" && notes.length == 0;
	}

	test "a newer format, a refusal, a failure and the timeout each end the wait with a note" {
		const [e, fake, f, notes] = formatting("a=1");
		f.run(false);
		f.run(false);
		assert fake.cancelled.length == 1 && fake.cancelled[0] == 1;
		fake.answers[0]([{ from: 0, to: 3, text: "lost" }], null);
		assert e.doc.text() == "a=1";
		fake.answers[1](null, "no formatter");
		assert notes.length == 1 && notes[0] == "formatting failed: no formatter";
		f.run(false);
		fake.timers[2]();
		fake.answers[2]([{ from: 0, to: 3, text: "late" }], null);
		assert e.doc.text() == "a=1" && notes[1] == "formatting timed out";
		fake.refuse = true;
		f.run(true);
		assert notes[2] == "no language server formats a selection of this file";
	}
}
