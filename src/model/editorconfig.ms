import { DEFAULT_INDENT } from "./indent";

const HONOURED = ["indent_style", "indent_size", "tab_width", "insert_final_newline", "trim_trailing_whitespace"];

export struct EditorConfigFile {
	dir: string;
	text: string;
}

export struct EditorSettings {
	hardTabs: boolean | null;
	indentSize: int32 | null;
	insertFinalNewline: boolean | null;
	trimTrailingWhitespace: boolean | null;
}

struct Section {
	glob: string;
	keys: string[];
	values: string[];
}

struct Parsed {
	root: boolean;
	sections: Section[];
}

function parse(text: string): Parsed {
	let root = false;
	const sections: Section[] = [];
	for (const raw of text.split("\n")) {
		const line = raw.trim();
		if (line == "" || line.startsWith("#") || line.startsWith(";")) { continue; }
		if (line.startsWith("[") && line.endsWith("]")) {
			sections.push({ glob: line.byteSlice(1, line.byteLength - 1), keys: [], values: [] });
			continue;
		}
		const eq = line.byteIndexOf("=", 0);
		if (eq < 0) { continue; }
		const key = line.byteSlice(0, eq).trim().toLowerCase();
		const value = line.byteSlice(eq + 1, line.byteLength).trim().toLowerCase();
		if (sections.length == 0) {
			if (key == "root") { root = value == "true"; }
			continue;
		}
		if (!HONOURED.includes(key)) { continue; }
		sections[sections.length - 1].keys.push(key);
		sections[sections.length - 1].values.push(value);
	}
	return { root, sections };
}

function closingBrace(p: string, open: int32): int32 {
	let depth = 0;
	for (let k = open; k < p.byteLength; k++) {
		const c = p.byteAt(k);
		if (c == "\\".code) { k += 1; }
		else if (c == "{".code) { depth += 1; }
		else if (c == "}".code) {
			depth -= 1;
			if (depth == 0) { return k; }
		}
	}
	return -1;
}

function alternatives(body: string): string[] {
	const parts: string[] = [];
	let depth = 0;
	let from = 0;
	for (let k = 0; k < body.byteLength; k++) {
		const c = body.byteAt(k);
		if (c == "\\".code) { k += 1; }
		else if (c == "{".code) { depth += 1; }
		else if (c == "}".code) { depth -= 1; }
		else if (c == ",".code && depth == 0) {
			parts.push(body.byteSlice(from, k));
			from = k + 1;
		}
	}
	parts.push(body.byteSlice(from, body.byteLength));
	return parts;
}

function isDigit(c: int32): boolean { return c >= "0".code && c <= "9".code; }

function integerAt(s: string, from: int32): [int32, int32] | null {
	let k = from;
	const negative = k < s.byteLength && s.byteAt(k) == "-".code;
	if (k < s.byteLength && (s.byteAt(k) == "-".code || s.byteAt(k) == "+".code)) { k += 1; }
	const digits = k;
	let value = 0;
	while (k < s.byteLength && isDigit(s.byteAt(k))) {
		value = value * 10 + s.byteAt(k) - "0".code;
		k += 1;
	}
	if (k == digits) { return null; }
	return [negative ? -value : value, k];
}

function numericRange(body: string): [int32, int32] | null {
	const dots = body.byteIndexOf("..", 0);
	if (dots < 0) { return null; }
	const low = integerAt(body, 0);
	const high = integerAt(body, dots + 2);
	if (low === null || high === null) { return null; }
	const [a, aEnd] = low as [int32, int32];
	const [b, bEnd] = high as [int32, int32];
	if (aEnd != dots || bEnd != body.byteLength) { return null; }
	return [Math.min(a, b), Math.max(a, b)];
}

function classMatches(set: string, c: int32): boolean {
	const negated = set.byteLength > 0 && set.byteAt(0) == "!".code;
	let found = false;
	let k = negated ? 1 : 0;
	while (k < set.byteLength) {
		const low = set.byteAt(k);
		if (k + 2 < set.byteLength && set.byteAt(k + 1) == "-".code) {
			if (c >= low && c <= set.byteAt(k + 2)) { found = true; }
			k += 3;
		} else {
			if (c == low) { found = true; }
			k += 1;
		}
	}
	return found != negated;
}

function atSegmentStart(t: string, ti: int32): boolean { return ti == 0 || t.byteAt(ti - 1) == "/".code; }

function globMatch(p: string, pi: int32, t: string, ti: int32): boolean {
	let i = pi;
	let j = ti;
	while (i < p.byteLength) {
		const c = p.byteAt(i);
		if (c == "*".code) {
			if (i + 1 < p.byteLength && p.byteAt(i + 1) == "*".code) {
				let rest = i;
				while (rest < p.byteLength && p.byteAt(rest) == "*".code) { rest += 1; }
				if (rest < p.byteLength && p.byteAt(rest) == "/".code && atSegmentStart(t, j)
					&& globMatch(p, rest + 1, t, j)) {
					return true;
				}
				for (let k = j; k <= t.byteLength; k++) {
					if (globMatch(p, rest, t, k)) { return true; }
				}
				return false;
			}
			for (let k = j; k <= t.byteLength; k++) {
				if (globMatch(p, i + 1, t, k)) { return true; }
				if (k < t.byteLength && t.byteAt(k) == "/".code) { return false; }
			}
			return false;
		}
		if (c == "?".code) {
			if (j >= t.byteLength || t.byteAt(j) == "/".code) { return false; }
			j += 1;
			while (j < t.byteLength && (t.byteAt(j) & 0xC0) == 0x80) { j += 1; }
			i += 1;
			continue;
		}
		if (c == "[".code) {
			const close = p.byteIndexOf("]", i + 2);
			if (close > 0) {
				if (j >= t.byteLength || t.byteAt(j) == "/".code || !classMatches(p.byteSlice(i + 1, close), t.byteAt(j))) {
					return false;
				}
				i = close + 1;
				j += 1;
				continue;
			}
		}
		if (c == "{".code) {
			const close = closingBrace(p, i);
			if (close > 0) {
				const body = p.byteSlice(i + 1, close);
				const rest = p.byteSlice(close + 1, p.byteLength);
				const range = numericRange(body);
				if (range !== null) {
					const [low, high] = range as [int32, int32];
					const n = integerAt(t, j);
					if (n === null) { return false; }
					const [value, end] = n as [int32, int32];
					return value >= low && value <= high && globMatch(rest, 0, t, end);
				}
				const alts = alternatives(body);
				if (alts.length > 1) {
					for (const alt of alts) {
						if (globMatch(alt + rest, 0, t, j)) { return true; }
					}
					return false;
				}
			}
		}
		let literal = c;
		if (c == "\\".code && i + 1 < p.byteLength) {
			i += 1;
			literal = p.byteAt(i);
		}
		if (j >= t.byteLength || t.byteAt(j) != literal) { return false; }
		i += 1;
		j += 1;
	}
	return j == t.byteLength;
}

export function sectionMatches(glob: string, path: string): boolean {
	if (!glob.includes("/")) { return globMatch("**/" + glob, 0, path, 0); }
	return globMatch(glob.startsWith("/") ? glob.byteSlice(1, glob.byteLength) : glob, 0, path, 0);
}

function relativeTo(dir: string, path: string): string | null {
	const base = dir.replaceAll("\\", "/");
	if (base == "") { return path; }
	const prefix = base.endsWith("/") ? base : base + "/";
	return path.startsWith(prefix) ? path.byteSlice(prefix.byteLength, path.byteLength) : null;
}

function flag(value: string | null): boolean | null {
	if (value == "true") { return true; }
	if (value == "false") { return false; }
	return null;
}

function size(value: string | null): int32 | null {
	if (value === null) { return null; }
	const n = integerAt(value as string, 0);
	if (n === null) { return null; }
	const [count, end] = n as [int32, int32];
	return end == (value as string).byteLength && count > 0 ? count : null;
}

export function editorConfigFor(files: EditorConfigFile[], path: string): EditorSettings {
	const target = path.replaceAll("\\", "/");
	const parsed: Parsed[] = [];
	let first = 0;
	for (let k = 0; k < files.length; k++) {
		parsed.push(parse(files[k].text));
		if (parsed[k].root) { first = k; }
	}
	const props = new Map<string, string>();
	for (let k = first; k < files.length; k++) {
		const relative = relativeTo(files[k].dir, target);
		if (relative === null) { continue; }
		for (const s of parsed[k].sections) {
			if (!sectionMatches(s.glob, relative as string)) { continue; }
			for (let n = 0; n < s.keys.length; n++) {
				if (s.values[n] == "unset") { props.delete(s.keys[n]); } else { props.set(s.keys[n], s.values[n]); }
			}
		}
	}
	const style = props.get("indent_style");
	let indentSize = props.get("indent_size");
	if (indentSize === null && style == "tab") { indentSize = "tab"; }
	return {
		hardTabs: style == "tab" ? true : style == "space" ? false : null,
		indentSize: indentSize == "tab" ? size(props.get("tab_width")) : size(indentSize),
		insertFinalNewline: flag(props.get("insert_final_newline")),
		trimTrailingWhitespace: flag(props.get("trim_trailing_whitespace")),
	};
}

export function indentFor(settings: EditorSettings, guessed: string): string {
	const width = settings.indentSize;
	if (settings.hardTabs === true) { return "\t"; }
	if (settings.hardTabs === null && (width === null || guessed == "\t")) { return guessed; }
	if (width !== null) { return " ".repeat(width as int32); }
	return guessed == "\t" ? DEFAULT_INDENT : guessed;
}

when (testBuild) {
	function settingsOf(files: EditorConfigFile[], path: string): string {
		const s = editorConfigFor(files, path);
		return `${s.hardTabs} ${s.indentSize} ${s.insertFinalNewline} ${s.trimTrailingWhitespace}`;
	}

	test "a section applies its honoured keys, case aside, and an unmatched path or an unknown key stays unset" {
		const files: EditorConfigFile[] = [{ dir: "", text: "# c\nroot = true\n\n[*.ts]\nIndent_Style = Space\nindent_size = 2\ninsert_final_newline = TRUE\nmax_line_length = 80\n" }];
		assert settingsOf(files, "src/a.ts") == "false 2 true null";
		assert settingsOf(files, "a.rs") == "null null null null";
	}

	test "globs match stars within a segment, double stars across, one character, classes, alternatives and ranges" {
		assert sectionMatches("*", "a/b/c.ms");
		assert sectionMatches("*.ms", "deep/x.ms") && !sectionMatches("*.ms", "x.ts");
		assert sectionMatches("src/*.ms", "src/a.ms") && !sectionMatches("src/*.ms", "src/a/b.ms");
		assert sectionMatches("src/**.ms", "src/a/b.ms");
		assert sectionMatches("/lib/**/x.c", "lib/x.c") && sectionMatches("lib/**/x.c", "lib/a/b/x.c");
		assert !sectionMatches("lib/x.c", "other/lib/x.c");
		assert sectionMatches("?.c", "a.c") && sectionMatches("?.c", "é.c") && !sectionMatches("?.c", "ab.c");
		assert sectionMatches("[Mm]akefile", "Makefile") && sectionMatches("[a-c].h", "b.h");
		assert !sectionMatches("[!a-c].h", "b.h") && sectionMatches("[!a-c].h", "d.h");
		assert sectionMatches("*.{js,ts}", "a.ts") && !sectionMatches("*.{js,ts}", "a.rs");
		assert sectionMatches("{package.json,.travis.yml}", "package.json");
		assert sectionMatches("file{1..3}.txt", "file2.txt") && !sectionMatches("file{1..3}.txt", "file4.txt");
		assert sectionMatches("{single}.c", "{single}.c") && sectionMatches("a\\*.c", "a*.c") && !sectionMatches("a\\*.c", "ab.c");
	}

	test "a later section wins over an earlier one, and a nearer file over a farther one" {
		const top: EditorConfigFile = { dir: "", text: "[*]\nindent_style = tab\ntrim_trailing_whitespace = true\n[*.md]\ntrim_trailing_whitespace = false\n" };
		const near: EditorConfigFile = { dir: "pkg", text: "[*]\nindent_style = space\nindent_size = 3\n[lib/*.ms]\nindent_size = 8\n" };
		assert settingsOf([top], "notes.md") == "true null null false";
		assert settingsOf([top, near], "pkg/a.ms") == "false 3 null true";
		assert settingsOf([top, near], "pkg/lib/a.ms") == "false 8 null true";
		assert settingsOf([top, near], "other/a.ms") == "true null null true";
	}

	test "root stops the files above it from applying" {
		const top: EditorConfigFile = { dir: "", text: "[*]\ninsert_final_newline = true\n" };
		const rooted: EditorConfigFile = { dir: "app", text: "root=true\n[*]\nindent_size = 4\n" };
		assert settingsOf([top, rooted], "app/x.c") == "null 4 null null";
		assert settingsOf([top], "app/x.c") == "null null true null";
	}

	test "a tab indent takes its width from tab_width, unset takes a key back, and a bad value counts as unset" {
		const files: EditorConfigFile[] = [{ dir: "", text: "[*]\nindent_style = tab\ntab_width = 8\n[*.go]\nindent_size = tab\n[*.py]\nindent_size = unset\n[*.sh]\nindent_size = unset\nindent_style = space\n[*.c]\nindent_size = 0\n" }];
		assert settingsOf(files, "a.go") == "true 8 null null";
		assert settingsOf(files, "a.rs") == "true 8 null null";
		assert settingsOf(files, "a.py") == "true 8 null null";
		assert settingsOf(files, "a.sh") == "false null null null";
		assert settingsOf(files, "a.c") == "true null null null";
	}

	test "the editor indent follows the style and size that are set and the guess for the rest" {
		const tabs: EditorSettings = { hardTabs: true, indentSize: 4, insertFinalNewline: null, trimTrailingWhitespace: null };
		const spaces: EditorSettings = { hardTabs: false, indentSize: 2, insertFinalNewline: null, trimTrailingWhitespace: null };
		const sized: EditorSettings = { hardTabs: null, indentSize: 3, insertFinalNewline: null, trimTrailingWhitespace: null };
		const spaced: EditorSettings = { hardTabs: false, indentSize: null, insertFinalNewline: null, trimTrailingWhitespace: null };
		assert indentFor(tabs, "  ") == "\t";
		assert indentFor(spaces, "\t") == "  ";
		assert indentFor(sized, "  ") == "   " && indentFor(sized, "\t") == "\t";
		assert indentFor(spaced, "\t") == DEFAULT_INDENT && indentFor(spaced, "  ") == "  ";
	}
}
