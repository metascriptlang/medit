import { Rope } from "../text/rope";

export const LOG_SIZE: int32 = 256;

export struct Edit {
	from: int32;
	to: int32;
	text: string;
}

export struct Change {
	from: int32;
	removed: int32;
	inserted: int32;
}

export enum Bias {
	Left,
	Right,
}

export struct Anchor {
	slot: int32;
	generation: int32;
}

struct AnchorSlot {
	offset: int32;
	bias: Bias;
	generation: int32;
	live: boolean;
}

export function mapOffset(offset: int32, change: Change, bias: Bias): int32 {
	if (offset < change.from) { return offset; }
	if (offset == change.from && change.removed == 0) { return bias == Bias.Left ? offset : offset + change.inserted; }
	if (offset >= change.from + change.removed) { return offset + change.inserted - change.removed; }
	return change.from + (bias == Bias.Left ? 0 : change.inserted);
}

export class Document {
	private rope: Rope;
	private current: int32;
	private log: Change[];
	private anchors: AnchorSlot[];
	private freeSlots: int32[];

	constructor(text: string) {
		this.rope = new Rope(text);
		this.current = 0;
		this.log = [];
		this.anchors = [];
		this.freeSlots = [];
	}

	version(): int32 { return this.current; }
	length(): int32 { return this.rope.length(); }
	lineCount(): int32 { return this.rope.lineCount(); }
	line(line: int32): string { return this.rope.line(line); }
	lineStart(line: int32): int32 { return this.rope.lineStart(line); }
	lineEnd(line: int32): int32 { return this.rope.lineEnd(line); }
	lineOf(offset: int32): int32 { return this.rope.lineOf(offset); }
	slice(from: int32, to: int32): string { return this.rope.slice(from, to); }
	byteAt(offset: int32): int32 { return this.rope.byteAt(offset); }
	text(): string { return this.rope.text(); }

	splice(edit: Edit): Edit {
		const removed = this.rope.slice(edit.from, edit.to);
		this.rope.replace(edit.from, edit.to, edit.text);
		const change: Change = {
			from: edit.from,
			removed: edit.to - edit.from,
			inserted: edit.text.byteLength,
		};
		this.current += 1;
		if ((this.log.length as int32) == LOG_SIZE) { this.log.shift(); }
		this.log.push(change);
		for (let i = 0; i < this.anchors.length; i++) {
			const slot = this.anchors[i];
			if (slot.live) { this.anchors[i] = { ...slot, offset: mapOffset(slot.offset, change, slot.bias) }; }
		}
		return { from: edit.from, to: edit.from + change.inserted, text: removed };
	}

	changesSince(version: int32): Change[] | null {
		const behind = this.current - version;
		if (behind < 0 || behind > (this.log.length as int32)) { return null; }
		return this.log.slice(this.log.length - behind);
	}

	anchor(offset: int32, bias: Bias): Anchor {
		if (offset < 0 || offset > this.length()) {
			throw new Error(`Document.anchor: offset ${offset} is outside 0..${this.length()}`);
		}
		if (this.freeSlots.length > 0) {
			const slot = this.freeSlots.pop() as int32;
			const generation = this.anchors[slot].generation + 1;
			this.anchors[slot] = { offset, bias, generation, live: true };
			return { slot, generation };
		}
		this.anchors.push({ offset, bias, generation: 0, live: true });
		return { slot: (this.anchors.length as int32) - 1, generation: 0 };
	}

	resolve(a: Anchor): int32 {
		return this.slotOf(a, "resolve").offset;
	}

	release(a: Anchor): void {
		const slot = this.slotOf(a, "release");
		this.anchors[a.slot] = { ...slot, live: false };
		this.freeSlots.push(a.slot);
	}

	private slotOf(a: Anchor, who: string): AnchorSlot {
		if (a.slot < 0 || a.slot >= (this.anchors.length as int32)) {
			throw new Error(`Document.${who}: anchor slot ${a.slot} does not exist`);
		}
		const slot = this.anchors[a.slot];
		if (!slot.live || slot.generation != a.generation) {
			throw new Error(`Document.${who}: anchor ${a.slot}/${a.generation} was released`);
		}
		return slot;
	}
}

test "splice returns the edit that undoes it" {
	const d = new Document("hello world");
	const inverse = d.splice({ from: 6, to: 11, text: "medic" });
	assert d.text() == "hello medic";
	assert d.version() == 1;
	const _back = d.splice(inverse);
	assert d.text() == "hello world";
	assert d.version() == 2;
}

test "the log answers what changed since a version" {
	const d = new Document("abc");
	const _a = d.splice({ from: 0, to: 0, text: "x" });
	const _b = d.splice({ from: 1, to: 2, text: "" });
	const since = d.changesSince(0);
	assert since !== null;
	if (since !== null) {
		assert since.length == 2;
		assert since[1].removed == 1;
	}
	const none = d.changesSince(2);
	assert none !== null;
	if (none !== null) { assert none.length == 0; }
}

test "a version older than the log asks for a full resync" {
	const d = new Document("");
	for (let i = 0; i < LOG_SIZE + 5; i++) { const _e = d.splice({ from: 0, to: 0, text: "a" }); }
	assert d.changesSince(0) === null;
	assert d.changesSince(5) !== null;
	assert d.changesSince(d.version() + 1) === null;
}

test "an insert at an anchor moves only a right-biased anchor" {
	const d = new Document("abcd");
	const left = d.anchor(2, Bias.Left);
	const right = d.anchor(2, Bias.Right);
	const _e = d.splice({ from: 2, to: 2, text: "XY" });
	assert d.resolve(left) == 2;
	assert d.resolve(right) == 4;
}

test "an anchor inside a deleted range collapses onto the edit" {
	const d = new Document("0123456789");
	const inside = d.anchor(5, Bias.Right);
	const after = d.anchor(8, Bias.Left);
	const _e = d.splice({ from: 3, to: 7, text: "ab" });
	assert d.resolve(inside) == 5;
	assert d.resolve(after) == 6;
	const before = d.anchor(1, Bias.Left);
	const _f = d.splice({ from: 3, to: 5, text: "" });
	assert d.resolve(before) == 1;
	assert d.resolve(inside) == 3;
}

test "a released anchor's slot is reused under a new generation" {
	const d = new Document("abc");
	const a = d.anchor(1, Bias.Left);
	d.release(a);
	const b = d.anchor(2, Bias.Left);
	assert b.slot == a.slot;
	assert b.generation == a.generation + 1;
	assert d.resolve(b) == 2;
}

test "mapping offsets through a replacement" {
	const c: Change = { from: 4, removed: 2, inserted: 5 };
	assert mapOffset(3, c, Bias.Right) == 3;
	assert mapOffset(4, c, Bias.Left) == 4;
	assert mapOffset(4, c, Bias.Right) == 9;
	assert mapOffset(5, c, Bias.Left) == 4;
	assert mapOffset(6, c, Bias.Right) == 9;
	assert mapOffset(6, c, Bias.Left) == 9;
	assert mapOffset(7, c, Bias.Left) == 10;
	const insert: Change = { from: 4, removed: 0, inserted: 3 };
	assert mapOffset(4, insert, Bias.Left) == 4;
	assert mapOffset(5, insert, Bias.Left) == 8;
	assert mapOffset(5, insert, Bias.Right) == 8;
}
