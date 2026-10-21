import { Anchor, Bias, Document } from "./document";

export enum Severity {
	Error = 1,
	Warning = 2,
	Information = 3,
	Hint = 4,
}

export struct Diagnostic {
	from: int32;
	to: int32;
	severity: Severity;
	message: string;
	source: string;
}

struct Held {
	from: Anchor;
	to: Anchor;
	severity: Severity;
	message: string;
	source: string;
}

export struct Tally {
	errors: int32;
	warnings: int32;
}

export class Diagnostics {
	private held: Vec<Held> = [];

	replace(doc: Document, found: Diagnostic[]): void {
		for (const h of this.held) {
			doc.release(h.from);
			doc.release(h.to);
		}
		this.held = [];
		for (const d of found) {
			const from = Math.max(0, Math.min(d.from, doc.length()));
			const to = Math.max(from, Math.min(d.to, doc.length()));
			this.held.push({
				from: doc.anchor(from, Bias.Right),
				to: doc.anchor(to, Bias.Left),
				severity: d.severity,
				message: d.message,
				source: d.source,
			});
		}
	}

	count(): int32 { return this.held.length as int32; }

	private resolved(doc: Document, h: Held): Diagnostic {
		const from = doc.resolve(h.from);
		return { from, to: Math.max(from, doc.resolve(h.to)), severity: h.severity, message: h.message, source: h.source };
	}

	all(doc: Document): Diagnostic[] {
		return this.held.map((h: Held): Diagnostic => this.resolved(doc, h));
	}

	within(doc: Document, from: int32, to: int32): Diagnostic[] {
		const out: Diagnostic[] = [];
		for (const h of this.held) {
			const d = this.resolved(doc, h);
			if (d.to >= from && d.from <= to) { out.push(d); }
		}
		return out;
	}

	at(doc: Document, offset: int32): Diagnostic[] {
		const out: Diagnostic[] = [];
		for (const h of this.held) {
			const d = this.resolved(doc, h);
			if (d.from <= offset && offset <= d.to) { out.push(d); }
		}
		out.sort((a: Diagnostic, b: Diagnostic): number => (a.severity as int32) - (b.severity as int32));
		return out;
	}

	tally(): Tally {
		let errors = 0;
		let warnings = 0;
		for (const h of this.held) {
			if (h.severity == Severity.Error) { errors += 1; }
			else if (h.severity == Severity.Warning) { warnings += 1; }
		}
		return { errors, warnings };
	}

	next(doc: Document, offset: int32, forward: boolean): Diagnostic | null {
		let worst: int32 = Severity.Hint as int32;
		for (const h of this.held) { worst = Math.min(worst, h.severity as int32); }
		let step: Diagnostic | null = null;
		let wrap: Diagnostic | null = null;
		for (const h of this.held) {
			if ((h.severity as int32) != worst) { continue; }
			const d = this.resolved(doc, h);
			const ahead = forward ? d.from > offset : d.from < offset;
			if (ahead && (step === null || (forward ? d.from < (step as Diagnostic).from : d.from > (step as Diagnostic).from))) {
				step = d;
			}
			if (wrap === null || (forward ? d.from < (wrap as Diagnostic).from : d.from > (wrap as Diagnostic).from)) {
				wrap = d;
			}
		}
		return step !== null ? step : wrap;
	}
}

test "diagnostics follow the text they mark as it is edited" {
	const d = new Document("let x = 1;\nlet y = x;\n");
	const set = new Diagnostics();
	set.replace(d, [
		{ from: 15, to: 16, severity: Severity.Warning, message: "unused", source: "ms" },
		{ from: 4, to: 5, severity: Severity.Error, message: "bad", source: "ms" },
	]);
	const _e = d.splice({ from: 0, to: 0, text: "// note\n" });
	const all = set.all(d);
	assert all.length == 2;
	assert all[0].from == 23 && all[0].to == 24;
	assert all[1].from == 12 && all[1].message == "bad";
	assert set.at(d, 12).length == 1 && set.at(d, 30).length == 0;
	assert set.within(d, 20, 40).length == 1;
	const t = set.tally();
	assert t.errors == 1 && t.warnings == 1;
}

test "replacing the set releases the old anchors" {
	const d = new Document("abc");
	const set = new Diagnostics();
	set.replace(d, [{ from: 0, to: 9, severity: Severity.Hint, message: "m", source: "" }]);
	assert set.all(d)[0].to == 3;
	set.replace(d, []);
	assert set.count() == 0;
	const a = d.anchor(1, Bias.Left);
	assert a.slot <= 1;
}

test "next steps among the most severe diagnostics, wrapping at the ends" {
	const d = new Document("0123456789");
	const set = new Diagnostics();
	set.replace(d, [
		{ from: 2, to: 3, severity: Severity.Error, message: "a", source: "" },
		{ from: 4, to: 5, severity: Severity.Hint, message: "h", source: "" },
		{ from: 7, to: 8, severity: Severity.Error, message: "b", source: "" },
	]);
	const n = set.next(d, 3, true);
	assert n !== null && (n as Diagnostic).message == "b";
	const w = set.next(d, 8, true);
	assert w !== null && (w as Diagnostic).message == "a";
	const p = set.next(d, 2, false);
	assert p !== null && (p as Diagnostic).message == "b";
	assert new Diagnostics().next(d, 0, true) === null;
}
