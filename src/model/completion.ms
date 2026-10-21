import { Bias, Document, Edit } from "./document";
import { Editor, mapThrough } from "./editor";
import { Sel, cursorAt, end, primaryRange, start } from "./selection";
import { indentEnd, isWordByte } from "./motion";
import { FuzzyMatch, charsOf, fuzzyMatch, isDigit, isLower, isUpper, lowered } from "../text/fuzzy";

const KIND_KEYWORD: int32 = 14;
const KIND_VARIABLE: int32 = 6;
const KIND_CONSTANT: int32 = 21;
const KIND_PROPERTY: int32 = 10;
const OTHER_KIND_KEY: int32 = 4;
const MAX_MATCHES: int32 = 1000;
const WORD_LOOKUP_LINES: int32 = 5000;
const MIN_WORD_QUERY: int32 = 3;

// Offsets in `replaceFrom`, `replaceTo` and `insertTo` name the document at version `at`, and
// those in `extra` the document at version `extraAt`, so the menu can map them onto the text
// as it is when the completion is accepted.
export struct Completion {
	label: string;
	detail: string;
	documentation: string;
	filterText: string;
	sortText: string | null;
	kind: int32;
	deprecated: boolean;
	newText: string;
	replaceFrom: int32;
	replaceTo: int32;
	insertTo: int32 | null;
	at: int32;
	extra: Edit[];
	extraAt: int32;
	resolved: boolean;
	raw: string;
	asIs: boolean;
}

export struct Choice {
	index: int32;
	positions: int32[];
}

struct Ranked {
	choice: Choice;
	score: float64;
	wordStart: boolean;
	exact: boolean;
	exactCase: int32;
	sortText: string | null;
	kindKey: int32;
	label: string;
}

function kindKey(kind: int32): int32 {
	if (kind == KIND_KEYWORD) { return 0; }
	if (kind == KIND_VARIABLE) { return 1; }
	if (kind == KIND_CONSTANT) { return 2; }
	if (kind == KIND_PROPERTY) { return 3; }
	return OTHER_KIND_KEY;
}

function alphanumeric(c: string): boolean {
	return isDigit(c) || isUpper(c) || isLower(c) || c.byteAt(0) >= 0x80;
}

function startsAWord(text: string, first: string): boolean {
	const chars = charsOf(text).text;
	for (let i = 0; i < (chars.length as int32); i++) {
		const boundary = i == 0
			|| (!isUpper(chars[i - 1]) && isUpper(chars[i]))
			|| (!alphanumeric(chars[i - 1]) && alphanumeric(chars[i]));
		if (boundary && lowered(chars[i]) == first) { return true; }
	}
	return false;
}

function exactCaseCount(query: string, text: string, positions: int32[]): int32 {
	const q = charsOf(query).text;
	let count = 0;
	for (let k = 0; k < (positions.length as int32) && k < (q.length as int32); k++) {
		if (charsOf(text.byteSlice(positions[k], text.byteLength)).text[0] == q[k]) { count += 1; }
	}
	return count;
}

function compareText(a: string, b: string): int32 {
	return a < b ? -1 : a > b ? 1 : 0;
}

function comparePositions(a: int32[], b: int32[]): int32 {
	for (let k = 0; k < (a.length as int32) && k < (b.length as int32); k++) {
		if (a[k] != b[k]) { return a[k] < b[k] ? -1 : 1; }
	}
	return (a.length as int32) - (b.length as int32);
}

function compareRanked(a: Ranked, b: Ranked): number {
	if (a.wordStart != b.wordStart) { return a.wordStart ? -1 : 1; }
	if (!a.wordStart) {
		if (a.score != b.score) { return a.score > b.score ? -1 : 1; }
		return a.choice.index - b.choice.index;
	}
	if (a.exact != b.exact) { return a.exact ? -1 : 1; }
	if (a.score != b.score) { return a.score > b.score ? -1 : 1; }
	const positions = comparePositions(a.choice.positions, b.choice.positions);
	if (positions != 0) { return positions; }
	if (a.exactCase != b.exactCase) { return b.exactCase - a.exactCase; }
	if (a.sortText !== b.sortText) {
		if (a.sortText === null) { return -1; }
		if (b.sortText === null) { return 1; }
		const sorted = compareText(a.sortText as string, b.sortText as string);
		if (sorted != 0) { return sorted; }
	}
	if (a.kindKey != b.kindKey) { return a.kindKey - b.kindKey; }
	const label = compareText(a.label, b.label);
	return label != 0 ? label : a.choice.index - b.choice.index;
}

// The completions whose filter text holds the query's characters in order, best first:
// those where the query's first character starts a word of the candidate, ranked by an exact
// match, the score, earlier match positions, characters matched in the query's case, the
// server's sort text, the kind and the label; the rest follow by score.
export function ranked(items: Completion[], query: string): Choice[] {
	const q = charsOf(query).text;
	const smartCase = q.some((c: string): boolean => isUpper(c));
	const first = q.length == 0 ? "" : lowered(q[0]);
	let found: Ranked[] = [];
	for (let i = 0; i < (items.length as int32); i++) {
		const c = items[i];
		const m = fuzzyMatch(query, c.filterText, smartCase);
		if (m === null) { continue; }
		const hit = m as FuzzyMatch;
		found.push({
			choice: { index: i, positions: hit.positions },
			score: hit.score,
			wordStart: first == "" || startsAWord(c.filterText, first),
			exact: c.filterText == query,
			exactCase: exactCaseCount(query, c.filterText, hit.positions),
			sortText: c.sortText,
			kindKey: kindKey(c.kind),
			label: c.label,
		});
	}
	if ((found.length as int32) > MAX_MATCHES) {
		found.sort((a: Ranked, b: Ranked) => a.score != b.score ? (a.score > b.score ? -1 : 1) : a.choice.index - b.choice.index);
		found = found.slice(0, MAX_MATCHES);
	}
	found.sort((a: Ranked, b: Ranked) => compareRanked(a, b));
	return found.map((r: Ranked): Choice => r.choice);
}

// The word typed so far before `offset`, or null when the byte before it is no word byte.
export function queryAt(doc: Document, offset: int32): string | null {
	let from = offset;
	while (from > 0 && isWordByte(doc.byteAt(from - 1))) { from -= 1; }
	return from < offset ? doc.slice(from, offset) : null;
}

export function wordAround(doc: Document, offset: int32): [int32, int32] {
	let from = offset;
	while (from > 0 && isWordByte(doc.byteAt(from - 1))) { from -= 1; }
	let to = offset;
	while (to < doc.length() && isWordByte(doc.byteAt(to))) { to += 1; }
	return [from, to];
}

export function bufferWords(doc: Document, offset: int32): Completion[] {
	const query = queryAt(doc, offset);
	if (query === null) { return []; }
	const typed = charsOf(query as string).text;
	if ((typed.length as int32) < MIN_WORD_QUERY) { return []; }
	const digits = typed.some((c: string): boolean => isDigit(c));
	const [from, to] = wordAround(doc, offset);
	const own = doc.slice(from, to);
	const line = doc.lineOf(offset);
	const text = doc.slice(
		doc.lineStart(Math.max(0, line - WORD_LOOKUP_LINES)),
		doc.lineEnd(Math.min(doc.lineCount() - 1, line + WORD_LOOKUP_LINES)),
	);
	const seen = new Set<string>();
	const words: Completion[] = [];
	const at = doc.version();
	const n = text.byteLength as int32;
	let start = -1;
	for (let k = 0; k <= n; k++) {
		if (k < n && isWordByte(text.byteAt(k))) {
			if (start < 0) { start = k; }
			continue;
		}
		if (start < 0) { continue; }
		const word = text.byteSlice(start, k);
		const lead = text.byteAt(start);
		start = -1;
		if (word == own || seen.has(word) || (!digits && lead >= "0".code && lead <= "9".code)) { continue; }
		seen.add(word);
		words.push({
			label: word, detail: "", documentation: "", filterText: word, sortText: null, kind: 0,
			deprecated: false, newText: word, replaceFrom: from, replaceTo: offset, insertTo: null, at,
			extra: [], extraAt: at, resolved: true, raw: "",
		});
	}
	return words;
}

function snippetPart(s: string, from: int32, nested: boolean): [string, int32] {
	let out = "";
	let k = from;
	const n = s.byteLength as int32;
	while (k < n) {
		const b = s.byteAt(k);
		if (b == "\\".code && k + 1 < n) {
			out += s.byteSlice(k + 1, k + 2);
			k += 2;
		} else if (nested && b == "}".code) {
			return [out, k + 1];
		} else if (b == "$".code && k + 1 < n && s.byteAt(k + 1) == "{".code) {
			let j = k + 2;
			while (j < n && (isWordByte(s.byteAt(j)))) { j += 1; }
			if (j < n && s.byteAt(j) == ":".code) {
				const [inner, after] = snippetPart(s, j + 1, true);
				out += inner;
				k = after;
			} else if (j < n && s.byteAt(j) == "|".code) {
				const close = s.byteIndexOf("|", j + 1);
				const choices = close < 0 ? "" : s.byteSlice(j + 1, close);
				const comma = choices.byteIndexOf(",");
				out += comma < 0 ? choices : choices.byteSlice(0, comma);
				k = close < 0 ? n : close + 2;
			} else {
				k = j < n ? j + 1 : n;
			}
		} else if (b == "$".code && k + 1 < n && isWordByte(s.byteAt(k + 1))) {
			k += 1;
			while (k < n && isWordByte(s.byteAt(k))) { k += 1; }
		} else {
			out += s.byteSlice(k, k + 1);
			k += 1;
		}
	}
	return [out, k];
}

// A snippet's text with its tab stops, placeholders' markup and variables taken out.
export function snippetText(snippet: string): string {
	return snippetPart(snippet, 0, false)[0];
}

export function edited(doc: Document, version: int32, e: Edit): Edit | null {
	const from = doc.offsetSince(version, e.from, Bias.Left);
	const to = doc.offsetSince(version, e.to, Bias.Right);
	if (from === null || to === null) { return null; }
	return { from: from as int32, to: Math.max(from as int32, to as int32), text: e.text };
}

// The range the completion replaces at `cursor`, offsets as the document is now. Unless
// `replace` decides it, the word after the cursor is replaced when the label ends with it,
// so completing inside a word does not leave its tail behind.
export function chosenRange(doc: Document, c: Completion, cursor: int32, replace: boolean | null): [int32, int32] | null {
	const from = doc.offsetSince(c.at, c.replaceFrom, Bias.Left);
	const replaceTo = doc.offsetSince(c.at, c.replaceTo, Bias.Right);
	if (from === null || replaceTo === null) { return null; }
	let to = replaceTo as int32;
	if (c.insertTo !== null) {
		const insertTo = doc.offsetSince(c.at, c.insertTo as int32, Bias.Right);
		if (insertTo === null) { return null; }
		const whole = replace !== null ? replace as boolean
			: to > cursor ? c.label.toLowerCase().endsWith(doc.slice(cursor, to).toLowerCase()) : true;
		if (!whole) { to = insertTo as int32; }
	}
	return [from as int32, Math.max(to, cursor)];
}

function indentedAt(e: Editor, text: string, at: int32): string {
	if (text.byteIndexOf("\n") < 0) { return text; }
	const line = e.doc.lineOf(at);
	const indent = e.doc.slice(e.doc.lineStart(line), Math.min(e.doc.indentEnd(line), at));
	const lines = text.split("\n");
	for (let k = 1; k < (lines.length as int32); k++) {
		let tabs = 0;
		while (tabs < lines[k].byteLength && lines[k].byteAt(tabs) == "\t".code) { tabs += 1; }
		const body = lines[k].byteSlice(tabs, lines[k].byteLength);
		lines[k] = body.byteLength == 0 && tabs == 0 ? "" : indent + e.indent.repeat(tabs) + body;
	}
	return lines.join("\n");
}

function overlaps(a: Edit, b: Edit): boolean {
	return a.from < b.to && b.from < a.to || (a.from == a.to && a.from == b.from) || (b.from == b.to && b.from == a.from);
}

struct Placed {
	edit: Edit;
	caret: int32;
}

// Applies the completion at every cursor: the primary one replaces `chosenRange`, and another
// takes the same text before and after it when it has that text too. Returns the number of the
// server's extra edits left out because they overlap the completion, or null when the
// completion's offsets name a version the document no longer remembers.
export function accept(e: Editor, c: Completion, replace: boolean | null, group: string): int32 | null {
	const doc = e.doc;
	const primary = e.selections.primaryRange();
	const range = chosenRange(doc, c, primary.head, replace);
	if (range === null) { return null; }
	const [from, to] = range as [int32, int32];
	const lookbehind = Math.max(0, primary.start() - from);
	const lookahead = Math.max(0, to - primary.end());
	const old = doc.slice(from, to);
	const prefix = old.byteSlice(0, Math.max(0, (old.byteLength as int32) - lookahead));
	const suffix = old.byteSlice(Math.min(lookbehind, old.byteLength as int32), old.byteLength);
	const placed: Placed[] = [];
	let lastTo = 0;
	for (let i = 0; i < (e.selections.ranges.length as int32); i++) {
		const s = e.selections.ranges[i];
		let r: [int32, int32] = i == e.selections.primary ? [from, to] : [s.start(), s.end()];
		if (i != e.selections.primary) {
			const before = r[0] - lookbehind;
			const prefixEnd = before + (prefix.byteLength as int32);
			if (before >= lastTo && prefixEnd <= doc.length() && doc.slice(before, prefixEnd) == prefix) {
				r = [before, r[1]];
				const after = r[1] + (suffix.byteLength as int32);
				if (after <= doc.length() && doc.slice(r[1], after) == suffix) { r = [r[0], r[1] + lookahead]; }
			}
		}
		placed.push({ edit: { from: r[0], to: r[1], text: c.asIs ? c.newText : indentedAt(e, c.newText, r[0]) }, caret: -1 });
		lastTo = r[1];
	}
	let skipped = 0;
	const extras: Edit[] = [];
	for (const x of c.extra) {
		const now = edited(doc, c.extraAt, x);
		const clear = now !== null && !placed.some((p: Placed): boolean => overlaps(now as Edit, p.edit))
			&& !extras.some((o: Edit): boolean => overlaps(now as Edit, o));
		if (clear) { extras.push(now as Edit); } else { skipped += 1; }
	}
	const all: Edit[] = placed.map((p: Placed): Edit => p.edit).concat(extras);
	const order: int32[] = [];
	for (let k = 0; k < (all.length as int32); k++) { order.push(k); }
	order.sort((a: int32, b: int32) => all[a].from != all[b].from ? all[a].from - all[b].from : a - b);
	e.begin();
	e.groupAs(group);
	const applied = e.change(order.map((k: int32): Edit => all[k]));
	const carets: Sel[] = placed.map((p: Placed): Sel => cursorAt(0));
	for (let j = 0; j < (order.length as int32); j++) {
		if (order[j] < (placed.length as int32)) { carets[order[j]] = cursorAt(applied[j].from + applied[j].inserted); }
	}
	e.select({ ranges: carets, primary: e.selections.primary });
	e.end();
	return skipped;
}

// Applies edits that arrive after the completion (a resolved item's extra edits) into its undo
// step when nothing moved the cursors since, keeping the cursors where they are in the text.
export function acceptLater(e: Editor, edits: Edit[], version: int32, group: string): int32 {
	const doc = e.doc;
	const now: Edit[] = [];
	let skipped = 0;
	for (const x of edits) {
		const m = edited(doc, version, x);
		const clear = m !== null && !now.some((o: Edit): boolean => overlaps(m as Edit, o));
		if (clear) { now.push(m as Edit); } else { skipped += 1; }
	}
	if (now.length == 0) { return skipped; }
	now.sort((a: Edit, b: Edit) => a.from - b.from);
	e.begin();
	e.groupAs(group);
	const before = e.selections;
	const applied = e.change(now);
	e.select({
		ranges: before.ranges.map((s: Sel): Sel => ({
			anchor: mapThrough(s.anchor, applied, Bias.Right),
			head: mapThrough(s.head, applied, Bias.Right),
		})),
		primary: before.primary,
	});
	e.end();
	return skipped;
}

when (testBuild) {
	import { single } from "./selection";

	function item(label: string, sortText: string | null, kind: int32): Completion {
		return {
			label, detail: "", documentation: "", filterText: label, sortText, kind, deprecated: false,
			newText: label, replaceFrom: 0, replaceTo: 0, insertTo: null, at: 0, extra: [], extraAt: 0,
			resolved: true, raw: "",
		};
	}

	function labels(items: Completion[], query: string): string {
		return ranked(items, query).map((c: Choice): string => items[c.index].label).join(",");
	}

	test "a match at a word start ranks first, then by score, positions, case and sort text" {
		const items = [item("isLogged", null, 6), item("log", "2", 3), item("logger", "1", 3), item("Log", "2", 3), item("blog", null, 6)];
		assert labels(items, "log") == "log,logger,Log,isLogged,blog";
		assert labels(items, "Log") == "Log,isLogged,logger,log,blog";
		assert labels(items, "lg") == "logger,log,Log,isLogged,blog";
		assert labels(items, "") == "blog,isLogged,logger,Log,log";
		assert labels(items, "xq") == "";
	}

	test "the query is the word before the cursor" {
		const d = new Document("console.lo x");
		assert queryAt(d, 10) == "lo";
		assert queryAt(d, 8) === null;
		assert queryAt(d, 12) == "x";
		const [from, to] = wordAround(d, 9);
		assert from == 8 && to == 10;
	}

	test "a snippet loses its tab stops and keeps placeholder and first choice text" {
		assert snippetText("log(${1:value})$0") == "log(value)";
		assert snippetText("for (${1:i} of ${2|xs,ys|}) {\n\t$0\n}") == "for (i of xs) {\n\t\n}";
		assert snippetText("a\\$b${1:x${2:y}}") == "a$bxy";
	}

	test "accepting replaces the typed word, and the tail too when the label ends with it" {
		const d = new Document("let v = con.x; conole");
		const e = new Editor(d);
		e.select(single(11));
		const c: Completion = { ...item("console", null, 6), replaceFrom: 8, replaceTo: 11, insertTo: 11 };
		const _typed = d.splice({ from: 11, to: 11, text: "s" });
		e.select(single(12));
		assert accept(e, c, null, "completion 1") == 0;
		assert d.slice(0, d.length()) == "let v = console.x; conole";
		assert e.selections.primaryRange().head == 15;
		e.select(single(22));
		const tail: Completion = { ...item("console", null, 6), at: d.version(), replaceFrom: 19, replaceTo: 25, insertTo: 22 };
		assert accept(e, tail, null, "completion 2") == 0;
		assert d.slice(19, d.length()) == "console";
		assert e.undo() && d.slice(19, d.length()) == "conole";
	}

	test "a completion of several lines takes the indent of its line and the document's indent unit, unless asked as is" {
		const d = new Document("\tif (x) ");
		const e = new Editor(d);
		e.indent = "  ";
		e.select(single(8));
		const block: Completion = { ...item("{}", null, 15), newText: "{\n\tbody;\n\n}", replaceFrom: 8, replaceTo: 8, insertTo: 8 };
		assert accept(e, block, null, "completion 1") == 0;
		assert d.text() == "\tif (x) {\n\t  body;\n\n\t}";
		assert e.undo();
		const kept: Completion = { ...block, asIs: true };
		assert accept(e, kept, null, "completion 2") == 0;
		assert d.text() == "\tif (x) {\n\tbody;\n\n}";
	}

	test "every cursor with the same typed prefix takes the completion, and late extra edits join its undo step" {
		const d = new Document("co\nco\nx");
		const e = new Editor(d);
		e.select({ ranges: [cursorAt(2), cursorAt(5), cursorAt(7)], primary: 0 });
		const c: Completion = { ...item("const", null, 14), replaceFrom: 0, replaceTo: 2, insertTo: 2 };
		assert accept(e, c, null, "completion 3") == 0;
		assert d.slice(0, d.length()) == "const\nconst\nxconst";
		assert e.selections.ranges[1].head == 11;
		const v = d.version();
		assert acceptLater(e, [{ from: 0, to: 0, text: "import x;\n" }], v, "completion 3") == 0;
		assert d.slice(0, 16) == "import x;\nconst\n" && e.selections.ranges[0].head == 15;
		assert e.undo() && d.slice(0, d.length()) == "co\nco\nx";
	}
}
