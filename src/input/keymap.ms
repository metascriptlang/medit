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

	commands(): string[] {
		const out: string[] = [];
		for (const [sequence, command] of this.bindings) { out.push(command); }
		return out;
	}

	firstKeys(): Map<string, string> {
		const out = new Map<string, string>();
		for (const [sequence, command] of this.bindings) {
			if (!out.has(command)) { out.set(command, sequence); }
		}
		return out;
	}
}

export function defaultKeymap(): Keymap {
	const keymap = new Keymap();
	const bindings: Array<[string, string]> = [
		["ArrowLeft", "left"], ["ArrowRight", "right"], ["ArrowUp", "up"], ["ArrowDown", "down"],
		["shift+ArrowLeft", "selectLeft"], ["shift+ArrowRight", "selectRight"],
		["shift+ArrowUp", "selectUp"], ["shift+ArrowDown", "selectDown"],
		["ctrl+ArrowLeft", "wordLeft"], ["ctrl+ArrowRight", "wordRight"],
		["ctrl+shift+ArrowLeft", "selectWordLeft"], ["ctrl+shift+ArrowRight", "selectWordRight"],
		["ctrl+alt+ArrowLeft", "subwordLeft"], ["ctrl+alt+ArrowRight", "subwordRight"],
		["ctrl+alt+shift+ArrowLeft", "selectSubwordLeft"],
		["ctrl+alt+shift+ArrowRight", "selectSubwordRight"],
		["Home", "home"], ["End", "end"], ["shift+Home", "selectHome"], ["shift+End", "selectEnd"],
		["ctrl+Home", "docStart"], ["ctrl+End", "docEnd"],
		["ctrl+shift+Home", "selectDocStart"], ["ctrl+shift+End", "selectDocEnd"],
		["PageUp", "pageUp"], ["PageDown", "pageDown"],
		["shift+PageUp", "selectPageUp"], ["shift+PageDown", "selectPageDown"],
		["ctrl+ArrowUp", "scrollLineUp"], ["ctrl+ArrowDown", "scrollLineDown"],
		["alt+PageUp", "scrollPageUp"], ["alt+PageDown", "scrollPageDown"],
		["ctrl+a", "selectAll"], ["ctrl+l", "selectLine"], ["ctrl+d", "selectNextOccurrence"],
		["ctrl+shift+l", "selectAllOccurrences"], ["ctrl+F2", "selectAllOccurrences"],
		["ctrl+F3", "selectNextOccurrence"], ["ctrl+shift+F3", "selectPreviousOccurrence"],
		["ctrl+k ctrl+d", "skipToNextOccurrence"],
		["ctrl+m", "moveToEnclosingBracket"],
		["ctrl+alt+ArrowUp", "addCursorAbove"], ["ctrl+alt+ArrowDown", "addCursorBelow"],
		["Escape", "collapse"], ["alt+z", "toggleWrap"],
		["ctrl+u", "undoSelection"], ["ctrl+shift+u", "redoSelection"],
		["ctrl+Enter", "newlineBelow"], ["ctrl+shift+Enter", "newlineAbove"],
		["alt+ArrowUp", "moveLineUp"], ["alt+ArrowDown", "moveLineDown"],
		["ctrl+alt+shift+ArrowUp", "duplicateLineUp"], ["ctrl+alt+shift+ArrowDown", "duplicateLineDown"],
		["alt+shift+ArrowUp", "duplicateLineUp"], ["alt+shift+ArrowDown", "duplicateLineDown"],
		["ctrl+shift+j", "joinLines"],
		["ctrl+shift+k", "deleteLine"], ["ctrl+/", "toggleComments"], ["ctrl+k ctrl+c", "toggleComments"],
		["alt+shift+a", "toggleBlockComments"], ["ctrl+k ctrl+/", "toggleBlockComments"],
		["Enter", "newline"], ["shift+Enter", "newline"], ["NumpadEnter", "newline"],
		["Tab", "tab"], ["shift+Tab", "outdent"],
		["ctrl+]", "indent"], ["ctrl+[", "outdent"],
		["ctrl+shift+[", "fold"], ["ctrl+shift+]", "unfoldLines"], ["ctrl+k ctrl+l", "toggleFold"],
		["ctrl+k ctrl+[", "foldRecursive"], ["ctrl+k ctrl+]", "unfoldRecursive"],
		["ctrl+k ctrl+0", "foldAll"], ["ctrl+k ctrl+j", "unfoldAll"],
		["ctrl+k ctrl+1", "foldAtLevel1"], ["ctrl+k ctrl+2", "foldAtLevel2"], ["ctrl+k ctrl+3", "foldAtLevel3"],
		["ctrl+k ctrl+4", "foldAtLevel4"], ["ctrl+k ctrl+5", "foldAtLevel5"], ["ctrl+k ctrl+6", "foldAtLevel6"],
		["ctrl+k ctrl+7", "foldAtLevel7"], ["ctrl+k ctrl+8", "foldAtLevel8"], ["ctrl+k ctrl+9", "foldAtLevel9"],
		["Backspace", "backspace"], ["shift+Backspace", "backspace"], ["Delete", "delete"],
		["ctrl+Backspace", "deleteWordLeft"], ["ctrl+Delete", "deleteWordRight"],
		["ctrl+alt+Backspace", "deleteSubwordLeft"], ["ctrl+alt+Delete", "deleteSubwordRight"],
		["alt+shift+h", "deleteSubwordLeft"], ["alt+shift+d", "deleteSubwordRight"],
		["ctrl+z", "undo"], ["ctrl+y", "redo"], ["ctrl+shift+z", "redo"],
		["ctrl+c", "copy"], ["ctrl+x", "cut"], ["ctrl+v", "paste"], ["ctrl+s", "save"],
		["ctrl+f", "find"], ["ctrl+g", "goToLine"], ["ctrl+h", "replace"], ["F3", "findNext"], ["shift+F3", "findPrev"],
		["ctrl+Insert", "copy"], ["shift+Delete", "cut"], ["shift+Insert", "paste"],
		["ctrl+k ctrl+i", "hover"], ["F12", "goToDefinition"], ["F8", "nextDiagnostic"], ["shift+F8", "prevDiagnostic"],
		["ctrl+Space", "showCompletions"], ["ctrl+i", "showSignatureHelp"], ["ctrl+shift+Space", "showSignatureHelp"],
		["alt+shift+f", "format"], ["ctrl+k ctrl+f", "formatSelections"],
		["F2", "rename"], ["shift+F12", "findReferences"], ["alt+shift+F12", "findReferences"],
		["F1", "palette"], ["ctrl+shift+p", "palette"],
		["ctrl+p", "quickOpen"], ["ctrl+e", "quickOpen"], ["ctrl+shift+f", "projectSearch"],
		["ctrl+w", "closeTab"], ["ctrl+F4", "closeTab"], ["ctrl+shift+t", "reopenClosedTab"],
		["ctrl+PageDown", "nextTab"], ["ctrl+PageUp", "previousTab"],
		["ctrl+Tab", "switchTabs"], ["ctrl+shift+Tab", "switchTabsBack"],
		["alt+1", "activateTab1"], ["alt+2", "activateTab2"], ["alt+3", "activateTab3"], ["alt+4", "activateTab4"], ["alt+5", "activateTab5"], ["alt+6", "activateTab6"], ["alt+7", "activateTab7"], ["alt+8", "activateTab8"], ["alt+9", "activateTab9"],
		["alt+0", "lastTab"],
		["ctrl+shift+o", "outline"], ["ctrl+.", "codeActions"], ["ctrl+shift+;", "toggleInlayHints"],
		["alt+ArrowLeft", "goBack"], ["alt+ArrowRight", "goForward"],
		["alt+shift+ArrowRight", "expandSelection"], ["alt+shift+ArrowLeft", "shrinkSelection"],
	];
	for (const [sequence, command] of bindings) { keymap.bind(sequence, command); }
	return keymap;
}

// Keys that act on the completion menu while it shows, ahead of the default map.
export function completionKeymap(): Keymap {
	const keymap = new Keymap();
	const bindings: Array<[string, string]> = [
		["ArrowUp", "completionPrevious"], ["ctrl+p", "completionPrevious"],
		["ArrowDown", "completionNext"], ["ctrl+n", "completionNext"],
		["PageUp", "completionFirst"], ["PageDown", "completionLast"],
		["Enter", "confirmCompletion"], ["NumpadEnter", "confirmCompletion"], ["Tab", "confirmCompletion"],
		["shift+Enter", "confirmCompletionReplace"], ["Escape", "hideCompletions"],
	];
	for (const [sequence, command] of bindings) { keymap.bind(sequence, command); }
	return keymap;
}

// Keys that act on the list below the cursor, of references or code actions, while it shows.
export function listKeymap(): Keymap {
	const keymap = new Keymap();
	const bindings: Array<[string, string]> = [
		["ArrowUp", "listPrevious"], ["ArrowDown", "listNext"],
		["PageUp", "listFirst"], ["PageDown", "listLast"],
		["Enter", "confirmList"], ["NumpadEnter", "confirmList"], ["Escape", "hideList"],
	];
	for (const [sequence, command] of bindings) { keymap.bind(sequence, command); }
	return keymap;
}

// Keys that act on signature help while it shows and the completion menu does not; the arrows
// only while it holds several signatures.
export function signatureKeymap(several: boolean): Keymap {
	const keymap = new Keymap();
	keymap.bind("Escape", "hideSignatureHelp");
	if (several) {
		keymap.bind("ArrowUp", "signaturePrevious");
		keymap.bind("ArrowDown", "signatureNext");
	}
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

function chord(m: Keymap, k: KeyPress): string {
	const r = m.feed(k);
	return r.outcome == Outcome.Run ? r.command : r.outcome.toString();
}

test "the default map binds line, occurrence, subword, scroll and selection history keys" {
	const m = defaultKeymap();
	const at = (key: string, ctrl: boolean, alt: boolean, shift: boolean): KeyPress =>
		({ key, ctrl, alt, shift, meta: false });
	assert chord(m, at("]", true, false, false)) == "indent";
	assert chord(m, at("[", true, false, false)) == "outdent";
	assert chord(m, at("J", true, false, true)) == "joinLines";
	assert chord(m, at("ArrowDown", false, true, true)) == "duplicateLineDown";
	assert chord(m, at("ArrowDown", true, true, true)) == "duplicateLineDown";
	assert chord(m, at("k", true, false, false)) == "Pending";
	assert chord(m, at("d", true, false, false)) == "skipToNextOccurrence";
	assert chord(m, at("F3", true, false, false)) == "selectNextOccurrence";
	assert chord(m, at("F3", true, false, true)) == "selectPreviousOccurrence";
	assert chord(m, at("ArrowLeft", true, true, false)) == "subwordLeft";
	assert chord(m, at("ArrowRight", true, true, true)) == "selectSubwordRight";
	assert chord(m, at("Backspace", true, true, false)) == "deleteSubwordLeft";
	assert chord(m, at("d", false, true, true)) == "deleteSubwordRight";
	assert chord(m, at("ArrowUp", true, false, false)) == "scrollLineUp";
	assert chord(m, at("PageDown", false, true, false)) == "scrollPageDown";
	assert chord(m, at("u", true, false, false)) == "undoSelection";
	assert chord(m, at("U", true, false, true)) == "redoSelection";
}

test "shift+alt+a and ctrl+k ctrl+/ toggle block comments" {
	const m = defaultKeymap();
	const at = (key: string, ctrl: boolean, alt: boolean, shift: boolean): KeyPress =>
		({ key, ctrl, alt, shift, meta: false });
	assert chord(m, at("A", false, true, true)) == "toggleBlockComments";
	assert chord(m, at("k", true, false, false)) == "Pending";
	assert chord(m, at("/", true, false, false)) == "toggleBlockComments";
}

test "the default map binds editing keys" {
	const m = defaultKeymap();
	const r = m.feed(press("z", true, true));
	assert r.outcome == Outcome.Run;
	assert r.command == "redo";
	assert m.feed(press("a", false, false)).outcome == Outcome.Unbound;
}

test "F1 and ctrl+shift+p open the palette, and a command's first key is the one bound first" {
	const m = defaultKeymap();
	assert chord(m, press("F1", false, false)) == "palette";
	assert chord(m, press("P", true, true)) == "palette";
	const first = m.firstKeys();
	assert first.get("palette") == "F1" && first.get("selectAllOccurrences") == "ctrl+shift+l";
	assert first.get("skipToNextOccurrence") == "ctrl+k ctrl+d" && first.get("copy") == "ctrl+c";
	assert !first.has("confirmList");
}

test "ctrl+p opens a file, ctrl+w closes the tab, ctrl+tab switches and alt+digit picks a tab" {
	const m = defaultKeymap();
	assert chord(m, press("p", true, false)) == "quickOpen";
	assert chord(m, press("w", true, false)) == "closeTab";
	assert chord(m, press("T", true, true)) == "reopenClosedTab";
	assert chord(m, press("Tab", true, false)) == "switchTabs" && chord(m, press("Tab", true, true)) == "switchTabsBack";
	assert chord(m, press("PageDown", true, false)) == "nextTab";
	assert chord(m, { key: "3", ctrl: false, alt: true, shift: false, meta: false }) == "activateTab3";
	assert chord(m, { key: "0", ctrl: false, alt: true, shift: false, meta: false }) == "lastTab";
}

test "fold keys: ctrl+shift+brackets fold and unfold, the rest follow ctrl+k" {
	const m = defaultKeymap();
	assert chord(m, press("[", true, true)) == "fold" && chord(m, press("]", true, true)) == "unfoldLines";
	const after = (key: string): string => {
		assert chord(m, press("k", true, false)) == "Pending";
		return chord(m, press(key, true, false));
	};
	assert after("l") == "toggleFold" && after("[") == "foldRecursive" && after("]") == "unfoldRecursive";
	assert after("0") == "foldAll" && after("j") == "unfoldAll" && after("1") == "foldAtLevel1" && after("9") == "foldAtLevel9";
}

test "ctrl+shift+f searches the project, and F3 keeps its find meaning" {
	const m = defaultKeymap();
	assert chord(m, press("F", true, true)) == "projectSearch";
	assert chord(m, press("f", false, false)) == "Unbound";
	assert chord(m, { key: "F", ctrl: false, alt: true, shift: true, meta: false }) == "format";
	assert chord(m, press("F3", false, false)) == "findNext" && chord(m, press("F3", false, true)) == "findPrev";
}
