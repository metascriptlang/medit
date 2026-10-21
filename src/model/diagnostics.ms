import { Anchor, Bias, Document } from "./document";
import { nextCluster, prevCluster } from "./motion";

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
	unnecessary: boolean;
}

struct Held {
	from: Anchor;
	to: Anchor;
	severity: Severity;
	message: string;
	source: string;
	unnecessary: boolean;
}

function widened(doc: Document, from: int32, to: int32): [int32, int32] {
	const line = doc.lineOf(from);
	if (from == to) {
		if (from < doc.lineEnd(line)) { return [from, doc.nextCluster(from)]; }
		return from > doc.lineStart(line) ? [doc.prevCluster(from), from] : [from, to];
	}
	if (from == doc.lineEnd(line) && line + 1 < doc.lineCount() && to == doc.lineStart(line + 1)) {
		return from > doc.lineStart(line) ? [doc.prevCluster(from), from] : [from, from];
	}
	return [from, to];
}

function same(a: Diagnostic, b: Diagnostic): boolean {
	return a.from == b.from && a.to == b.to && a.message == b.message;
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
			const clipped = Math.max(0, Math.min(d.from, doc.length()));
			const [from, to] = widened(doc, clipped, Math.max(clipped, Math.min(d.to, doc.length())));
			this.held.push({
				from: doc.anchor(from, Bias.Right),
				to: doc.anchor(to, Bias.Left),
				severity: d.severity,
				message: d.message,
				source: d.source,
				unnecessary: d.unnecessary,
			});
		}
	}

	count(): int32 { return this.held.length as int32; }

	private resolved(doc: Document, h: Held): Diagnostic {
		const from = doc.resolve(h.from);
		return {
			from,
			to: Math.max(from, doc.resolve(h.to)),
			severity: h.severity,
			message: h.message,
			source: h.source,
			unnecessary: h.unnecessary,
		};
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

	next(doc: Document, cursor: int32, forward: boolean, active: Diagnostic | null): Diagnostic | null {
		const list = this.all(doc).filter((d: Diagnostic): boolean => d.to > d.from && !d.unnecessary);
		list.sort((a: Diagnostic, b: Diagnostic): number => a.from - b.from);
		const after = list.filter((d: Diagnostic): boolean => d.from >= cursor);
		const before = list.filter((d: Diagnostic): boolean => d.from <= cursor);
		const isActive = (d: Diagnostic): boolean => active !== null && same(d, active as Diagnostic);
		let target: Diagnostic | null = null;
		let onActive = false;
		for (const d of after.concat(before)) {
			if (!(d.from <= cursor && cursor < d.to) && d.to != cursor) { continue; }
			if (isActive(d)) { onActive = true; } else if (target === null) { target = d; }
		}
		if (target !== null && !onActive) { return target; }
		let at = -1;
		for (let i = 0; i < (list.length as int32); i++) {
			if (list[i].from == cursor && isActive(list[i])) { at = i; }
		}
		const beside = forward ? at + 1 : at - 1;
		if (at >= 0 && beside >= 0 && beside < (list.length as int32) && list[beside].from == cursor) { return list[beside]; }
		let order = after.concat(before);
		if (!forward) {
			before.reverse();
			after.reverse();
			order = before.concat(after);
		}
		for (const d of order) {
			if (d.from != cursor) { return d; }
		}
		return null;
	}
}

test "diagnostics follow the text they mark as it is edited" {
	const d = new Document("let x = 1;\nlet y = x;\n");
	const set = new Diagnostics();
	set.replace(d, [
		{ from: 15, to: 16, severity: Severity.Warning, message: "unused", source: "ms", unnecessary: false },
		{ from: 4, to: 5, severity: Severity.Error, message: "bad", source: "ms", unnecessary: false },
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
	set.replace(d, [{ from: 0, to: 9, severity: Severity.Hint, message: "m", source: "", unnecessary: false }]);
	assert set.all(d)[0].to == 3;
	set.replace(d, []);
	assert set.count() == 0;
	const a = d.anchor(1, Bias.Left);
	assert a.slot <= 1;
}

function hint(from: int32, to: int32, message: string): Diagnostic {
	return { from, to, severity: Severity.Hint, message, source: "", unnecessary: false };
}

test "next lands on the diagnostic under the cursor, then steps on, wrapping at the ends" {
	const d = new Document("0123456789");
	const set = new Diagnostics();
	set.replace(d, [hint(2, 4, "a"), hint(7, 8, "b"), { ...hint(5, 6, "faded"), unnecessary: true }]);
	const under = set.next(d, 3, true, null);
	assert under !== null && (under as Diagnostic).message == "a";
	const on = set.next(d, 2, true, under);
	assert on !== null && (on as Diagnostic).message == "b";
	const w = set.next(d, 7, true, on);
	assert w !== null && (w as Diagnostic).message == "a";
	const p = set.next(d, 2, false, w);
	assert p !== null && (p as Diagnostic).message == "b";
	assert new Diagnostics().next(d, 0, true, null) === null;
}

test "diagnostics at one place are visited in turn" {
	const d = new Document("0123456789");
	const set = new Diagnostics();
	set.replace(d, [hint(2, 4, "a"), hint(2, 3, "a2"), hint(6, 7, "b")]);
	const first = set.next(d, 0, true, null);
	assert first !== null && (first as Diagnostic).message == "a";
	const second = set.next(d, 2, true, first);
	assert second !== null && (second as Diagnostic).message == "a2";
	const third = set.next(d, 2, true, second);
	assert third !== null && (third as Diagnostic).message == "b";
}

test "an empty range widens to the character after it, or before it at a line end" {
	const d = new Document("ab\ncd");
	const set = new Diagnostics();
	set.replace(d, [hint(1, 1, "mid"), hint(2, 2, "end"), hint(2, 3, "newline")]);
	const all = set.all(d);
	assert all[0].from == 1 && all[0].to == 2;
	assert all[1].from == 1 && all[1].to == 2;
	assert all[2].from == 1 && all[2].to == 2;
}
