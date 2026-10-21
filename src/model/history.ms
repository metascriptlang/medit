import { Anchor, Bias, Document } from "./document";

const MIN_ROWS: int32 = 10;
const MAX_SPOTS: int32 = 1024;

// A cursor place and the first line then shown, which the history keeps for the view.
export struct Spot {
	at: int32;
	top: int32;
}

struct Held {
	at: Anchor;
	top: int32;
}

// Where the cursor was before it moved far, to go back there and forward again. A move of fewer
// than ten lines is kept only when it was a jump; a new place drops the way forward, and a stack
// keeps one place per line.
export class NavHistory {
	private doc: Document;
	private behind: Held[] = [];
	private ahead: Held[] = [];

	constructor(doc: Document) { this.doc = doc; }

	moved(from: Spot, to: int32, jump: boolean): void {
		const rows = Math.abs(this.doc.lineOf(to) - this.doc.lineOf(from.at));
		if (rows == 0 || (rows < MIN_ROWS && !jump)) { return; }
		this.behind = this.kept(this.behind, from);
		for (const h of this.ahead) { this.doc.release(h.at); }
		this.ahead = [];
	}

	back(here: Spot): Spot | null {
		const [to, from, ahead] = this.gone(this.behind, this.ahead, here);
		this.behind = from;
		this.ahead = ahead;
		return to;
	}

	onward(here: Spot): Spot | null {
		const [to, from, behind] = this.gone(this.ahead, this.behind, here);
		this.ahead = from;
		this.behind = behind;
		return to;
	}

	private gone(from: Held[], into: Held[], here: Spot): [Spot | null, Held[], Held[]] {
		const left = from.slice(0);
		while (left.length > 0) {
			const h = left.pop() as Held;
			const at = this.doc.resolve(h.at);
			this.doc.release(h.at);
			if (at != here.at) { return [{ at, top: h.top }, left, this.kept(into, here)]; }
		}
		return [null, left, into];
	}

	private kept(stack: Held[], s: Spot): Held[] {
		const line = this.doc.lineOf(s.at);
		const out: Held[] = [];
		for (const h of stack) {
			if (this.doc.lineOf(this.doc.resolve(h.at)) == line) { this.doc.release(h.at); }
			else { out.push(h); }
		}
		if ((out.length as int32) >= MAX_SPOTS) { this.doc.release(out[0].at); }
		const next = (out.length as int32) >= MAX_SPOTS ? out.slice(1) : out;
		next.push({ at: this.doc.anchor(s.at, Bias.Left), top: s.top });
		return next;
	}
}

when (testBuild) {
	function lines(n: int32): string {
		let text = "";
		for (let i = 0; i < n; i++) { text += `line ${i}\n`; }
		return text;
	}

	test "a far move or a jump is kept, a near move is not, and back and onward walk the places" {
		const d = new Document(lines(40));
		const h = new NavHistory(d);
		const at = (line: int32): int32 => d.lineStart(line);
		h.moved({ at: at(0), top: 0 }, at(3), false);
		assert h.back({ at: at(3), top: 0 }) === null;
		h.moved({ at: at(3), top: 0 }, at(20), false);
		h.moved({ at: at(20), top: 12 }, at(22), true);
		const first = h.back({ at: at(22), top: 12 }) as Spot;
		assert first.at == at(20) && first.top == 12;
		const second = h.back({ at: at(20), top: 12 }) as Spot;
		assert second.at == at(3) && second.top == 0;
		assert h.back({ at: at(3), top: 0 }) === null;
		const next = h.onward({ at: at(3), top: 0 }) as Spot;
		assert next.at == at(20);
		h.moved({ at: at(20), top: 12 }, at(39), false);
		assert h.onward({ at: at(39), top: 30 }) === null;
	}

	test "places follow edits, one per line, and the cursor's own place is skipped" {
		const d = new Document(lines(40));
		const h = new NavHistory(d);
		const at = (line: int32): int32 => d.lineStart(line);
		h.moved({ at: at(5) + 2, top: 0 }, at(30), false);
		h.moved({ at: at(30), top: 20 }, at(5), false);
		h.moved({ at: at(5), top: 0 }, at(30), false);
		const _e = d.splice({ from: 0, to: 0, text: "new\n" });
		const back = h.back({ at: at(31), top: 20 }) as Spot;
		assert back.at == at(6) && back.top == 0;
		assert (h.back({ at: at(6), top: 0 }) as Spot).at == at(31);
		assert h.back({ at: at(31), top: 20 }) === null;
	}
}
