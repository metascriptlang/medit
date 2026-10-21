import { nextClusterIn } from "../text/clusters";

export enum WordCase {
	Title,
	Snake,
	Kebab,
	UpperCamel,
	LowerCamel,
}

function characters(text: string): string[] {
	const bytes = text.asBytes();
	const out: string[] = [];
	let at = 0;
	while (at < text.byteLength) {
		const next = nextClusterIn(bytes, at);
		out.push(text.byteSlice(at, next));
		at = next;
	}
	return out;
}

function isUpper(ch: string): boolean { return ch.toLowerCase() != ch; }
function isLower(ch: string): boolean { return ch.toUpperCase() != ch; }
function isLetter(ch: string): boolean { return isUpper(ch) || isLower(ch); }
function isDigit(ch: string): boolean {
	return ch.byteLength == 1 && ch.byteAt(0) >= "0".code && ch.byteAt(0) <= "9".code;
}
function isSeparator(ch: string): boolean { return ch == "_" || ch == "-" || ch == " "; }

function splitsBefore(chars: string[], i: int32): boolean {
	const left = chars[i - 1];
	const here = chars[i];
	const acronymEnds = i + 1 < chars.length && isUpper(left) && isUpper(here) &&
		isLower(chars[i + 1]);
	return (isLower(left) && isUpper(here)) || acronymEnds ||
		(isLetter(left) && isDigit(here)) || (isDigit(left) && isLetter(here));
}

function wordsOf(text: string): string[] {
	const chars = characters(text);
	const words: string[] = [];
	let word = "";
	for (let i = 0; i < chars.length; i++) {
		if (isSeparator(chars[i])) {
			if (word != "") { words.push(word); }
			word = "";
			continue;
		}
		if (word != "" && splitsBefore(chars, i)) {
			words.push(word);
			word = "";
		}
		word += chars[i];
	}
	if (word != "") { words.push(word); }
	return words;
}

function capitalized(word: string): string {
	const first = characters(word)[0];
	return first.toUpperCase() + word.byteSlice(first.byteLength, word.byteLength).toLowerCase();
}

function joinedAs(words: string[], style: WordCase): string {
	const parts: string[] = [];
	for (let i = 0; i < words.length; i++) {
		const w = words[i];
		parts.push(match (style) {
			WordCase.Snake | WordCase.Kebab => w.toLowerCase(),
			WordCase.LowerCamel when i == 0 => w.toLowerCase(),
			_ => capitalized(w),
		});
	}
	const glue = match (style) {
		WordCase.Title => " ",
		WordCase.Snake => "_",
		WordCase.Kebab => "-",
		_ => "",
	};
	return parts.join(glue);
}

export function toWordCase(text: string, style: WordCase): string {
	const lines: string[] = [];
	for (const line of text.split("\n")) {
		const rest = line.trimStart();
		const trimmed = rest.trimEnd();
		const leading = line.byteSlice(0, line.byteLength - rest.byteLength);
		const trailing = rest.byteSlice(trimmed.byteLength, rest.byteLength);
		lines.push(leading + joinedAs(wordsOf(trimmed), style) + trailing);
	}
	return lines.join("\n");
}

export function oppositeCase(text: string): string {
	let out = "";
	for (const ch of characters(text)) { out += isUpper(ch) ? ch.toLowerCase() : ch.toUpperCase(); }
	return out;
}

export function toggledCase(text: string): string {
	return text.toLowerCase() != text ? text.toLowerCase() : text.toUpperCase();
}

export function sortedLines(lines: string[], ignoreCase: boolean): string[] {
	if (!ignoreCase) {
		const sorted = lines.slice(0, lines.length);
		sorted.sort();
		return sorted;
	}
	const byKey = new Map<string, string[]>();
	for (const line of lines) {
		const key = line.toLowerCase();
		const same = byKey.get(key);
		if (same === undefined) { byKey.set(key, [line]); }
		else { same.push(line); }
	}
	const keys: string[] = [];
	for (const key of byKey) { keys.push(key); }
	keys.sort();
	const out: string[] = [];
	for (const key of keys) {
		for (const line of byKey.get(key) as string[]) { out.push(line); }
	}
	return out;
}

export function uniqueLines(lines: string[], ignoreCase: boolean): string[] {
	const seen = new Set<string>();
	const out: string[] = [];
	for (const line of lines) {
		const key = ignoreCase ? line.toLowerCase() : line;
		if (!seen.has(key)) {
			seen.add(key);
			out.push(line);
		}
	}
	return out;
}

export function reversedLines(lines: string[]): string[] {
	const out = lines.slice(0, lines.length);
	out.reverse();
	return out;
}

test "words split at separators, lower to upper, acronym ends and digits" {
	assert toWordCase("hello_world fooBar", WordCase.Title) == "Hello World Foo Bar";
	assert toWordCase("HTTPRequest", WordCase.Snake) == "http_request";
	assert toWordCase("vector4d", WordCase.Snake) == "vector_4_d";
	assert toWordCase("fooBar baz", WordCase.Kebab) == "foo-bar-baz";
	assert toWordCase("hyphens-and_underscores", WordCase.UpperCamel) == "HyphensAndUnderscores";
	assert toWordCase("Foo bar", WordCase.LowerCamel) == "fooBar";
	assert toWordCase("__a--b", WordCase.Snake) == "a_b";
	assert toWordCase("foo.bar", WordCase.Snake) == "foo.bar";
}

test "each line keeps its own leading and trailing blanks" {
	assert toWordCase("  foo bar \n\tbazQux", WordCase.Snake) == "  foo_bar \n\tbaz_qux";
	assert toWordCase("   ", WordCase.Title) == "   ";
}

test "opposite case flips each letter, toggled case lowers text that holds an upper letter" {
	assert oppositeCase("aBc1-D") == "AbC1-d";
	assert toggledCase("abC") == "abc";
	assert toggledCase("ab1") == "AB1";
}

test "sorting by bytes or ignoring case, the ties keep their order" {
	const sorted = sortedLines(["b", "a", "C", "B", "A"], false);
	assert sorted.join(",") == "A,B,C,a,b";
	const folded = sortedLines(["b", "a", "C", "B", "A", "c"], true);
	assert folded.join(",") == "a,A,b,B,C,c";
}

test "unique lines keep the first of each, reversed lines turn the order over" {
	assert uniqueLines(["a", "b", "a", "A"], false).join(",") == "a,b,A";
	assert uniqueLines(["a", "b", "a", "A"], true).join(",") == "a,b";
	assert reversedLines(["a", "b", "c"]).join(",") == "c,b,a";
}
