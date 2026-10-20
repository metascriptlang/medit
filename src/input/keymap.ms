export struct KeyPress {
	key: string;
	ctrl: boolean;
	alt: boolean;
	shift: boolean;
	meta: boolean;
}

export enum Outcome {
	Run,
	Pending,
	Cancelled,
	Unbound,
}

export struct Resolution {
	outcome: Outcome;
	command: string;
}

export function chordOf(k: KeyPress): string {
	const key = match (k.key) {
		" " => "Space",
		_ when k.key.length == 1 => k.key.toLowerCase(),
		_ => k.key,
	};
	return (k.ctrl ? "ctrl+" : "") + (k.alt ? "alt+" : "") + (k.shift ? "shift+" : "") +
		(k.meta ? "meta+" : "") + key;
}

export class Keymap {
	private bindings: Map<string, string> = new Map<string, string>();
	private prefixes: Set<string> = new Set<string>();
	private pending: string = "";

	bind(sequence: string, command: string): void {
		let space = sequence.indexOf(" ");
		while (space >= 0) {
			const prefix = sequence.slice(0, space);
			if (this.bindings.has(prefix)) {
				throw new Error(
					`Keymap.bind: "${sequence}" extends "${prefix}", which is bound already`,
				);
			}
			this.prefixes.add(prefix);
			space = sequence.indexOf(" ", space + 1);
		}
		if (this.prefixes.has(sequence)) {
			throw new Error(`Keymap.bind: "${sequence}" is a prefix of a longer binding`);
		}
		this.bindings.set(sequence, command);
	}

	feed(k: KeyPress): Resolution {
		const chord = chordOf(k);
		const sequence = this.pending == "" ? chord : `${this.pending} ${chord}`;
		const command = this.bindings.get(sequence);
		if (command !== undefined) {
			this.pending = "";
			return { outcome: Outcome.Run, command };
		}
		if (this.prefixes.has(sequence)) {
			this.pending = sequence;
			return { outcome: Outcome.Pending, command: "" };
		}
		const broke = this.pending != "";
		this.pending = "";
		return { outcome: broke ? Outcome.Cancelled : Outcome.Unbound, command: "" };
	}

	pendingChords(): string { return this.pending; }
}

export function defaultKeymap(): Keymap {
	const keymap = new Keymap();
	const bindings: Array<[string, string]> = [
		["ArrowLeft", "left"], ["ArrowRight", "right"], ["ArrowUp", "up"], ["ArrowDown", "down"],
		["shift+ArrowLeft", "selectLeft"], ["shift+ArrowRight", "selectRight"],
		["shift+ArrowUp", "selectUp"], ["shift+ArrowDown", "selectDown"],
		["ctrl+ArrowLeft", "wordLeft"], ["ctrl+ArrowRight", "wordRight"],
		["ctrl+shift+ArrowLeft", "selectWordLeft"], ["ctrl+shift+ArrowRight", "selectWordRight"],
		["Home", "home"], ["End", "end"], ["shift+Home", "selectHome"], ["shift+End", "selectEnd"],
		["ctrl+Home", "docStart"], ["ctrl+End", "docEnd"],
		["ctrl+shift+Home", "selectDocStart"], ["ctrl+shift+End", "selectDocEnd"],
		["PageUp", "pageUp"], ["PageDown", "pageDown"],
		["shift+PageUp", "selectPageUp"], ["shift+PageDown", "selectPageDown"],
		["ctrl+a", "selectAll"], ["ctrl+l", "selectLine"], ["ctrl+d", "selectNextOccurrence"],
		["ctrl+shift+l", "selectAllOccurrences"], ["ctrl+F2", "selectAllOccurrences"],
		["ctrl+alt+ArrowUp", "addCursorAbove"], ["ctrl+alt+ArrowDown", "addCursorBelow"],
		["Escape", "collapse"], ["alt+z", "toggleWrap"],
		["ctrl+Enter", "newlineBelow"], ["ctrl+shift+Enter", "newlineAbove"],
		["alt+ArrowUp", "moveLineUp"], ["alt+ArrowDown", "moveLineDown"],
		["ctrl+alt+shift+ArrowUp", "duplicateLineUp"], ["ctrl+alt+shift+ArrowDown", "duplicateLineDown"],
		["ctrl+shift+k", "deleteLine"], ["ctrl+/", "toggleComments"], ["ctrl+k ctrl+c", "toggleComments"],
		["Enter", "newline"], ["shift+Enter", "newline"], ["NumpadEnter", "newline"],
		["Tab", "tab"], ["shift+Tab", "outdent"],
		["Backspace", "backspace"], ["shift+Backspace", "backspace"], ["Delete", "delete"],
		["ctrl+Backspace", "deleteWordLeft"], ["ctrl+Delete", "deleteWordRight"],
		["ctrl+z", "undo"], ["ctrl+y", "redo"], ["ctrl+shift+z", "redo"],
		["ctrl+c", "copy"], ["ctrl+x", "cut"], ["ctrl+v", "paste"], ["ctrl+s", "save"],
		["ctrl+f", "find"], ["ctrl+h", "replace"], ["F3", "findNext"], ["shift+F3", "findPrev"],
		["ctrl+Insert", "copy"], ["shift+Delete", "cut"], ["shift+Insert", "paste"],
	];
	for (const [sequence, command] of bindings) { keymap.bind(sequence, command); }
	return keymap;
}

function press(key: string, ctrl: boolean, shift: boolean): KeyPress {
	return { key, ctrl, alt: false, shift, meta: false };
}

test "a chord names its modifiers in one order and lowercases a letter" {
	assert chordOf(press("Z", true, true)) == "ctrl+shift+z";
	assert chordOf(press(" ", true, false)) == "ctrl+Space";
	assert chordOf(press("ArrowLeft", false, true)) == "shift+ArrowLeft";
}

test "a sequence waits on its prefix, runs when complete, and a wrong key cancels it" {
	const m = defaultKeymap();
	m.bind("ctrl+k ctrl+c", "comment");
	const first = m.feed(press("k", true, false));
	assert first.outcome == Outcome.Pending;
	assert m.pendingChords() == "ctrl+k";
	const second = m.feed(press("c", true, false));
	assert second.outcome == Outcome.Run;
	assert second.command == "comment";
	const _again = m.feed(press("k", true, false));
	assert m.feed(press("q", false, false)).outcome == Outcome.Cancelled;
	assert m.feed(press("q", false, false)).outcome == Outcome.Unbound;
}

test "a three-chord sequence waits on both of its prefixes" {
	const m = new Keymap();
	m.bind("a b c", "abc");
	assert m.feed(press("a", false, false)).outcome == Outcome.Pending;
	assert m.feed(press("b", false, false)).outcome == Outcome.Pending;
	assert m.pendingChords() == "a b";
	const done = m.feed(press("c", false, false));
	assert done.outcome == Outcome.Run && done.command == "abc";
	assert m.pendingChords() == "";
}

test "binding over a prefix or under a binding is refused" {
	const m = new Keymap();
	m.bind("ctrl+k ctrl+c", "comment");
	let refused = 0;
	try { m.bind("ctrl+k", "x"); } catch (e) { refused += 1; }
	m.bind("ctrl+j", "join");
	try { m.bind("ctrl+j ctrl+j", "y"); } catch (e) { refused += 1; }
	assert refused == 2;
}

test "the default map binds editing keys" {
	const m = defaultKeymap();
	const r = m.feed(press("z", true, true));
	assert r.outcome == Outcome.Run;
	assert r.command == "redo";
	assert m.feed(press("a", false, false)).outcome == Outcome.Unbound;
}
