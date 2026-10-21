const FENCE = "```";
const TAB_SPACES = "    ";

export enum LineKind {
	Prose,
	Code,
	Rule,
}

export struct HoverLine {
	text: string;
	kind: LineKind;
	block: int32;
	at: int32;
}

export struct CodeBlock {
	language: string;
	source: string;
}

export struct Hover {
	lines: HoverLine[];
	blocks: CodeBlock[];
}

function inline(text: string): string {
	let out = "";
	let i = 0;
	while (i < text.length) {
		const c = text.charAt(i);
		if (c == "\\" && i + 1 < text.length) {
			out += text.charAt(i + 1);
			i += 2;
		} else if (text.slice(i, i + 2) == "**") {
			i += 2;
		} else if (c == "`") {
			i += 1;
		} else if (c == "[") {
			const close = text.indexOf("](", i);
			const end = close < 0 ? -1 : text.indexOf(")", close);
			if (end < 0) {
				out += c;
				i += 1;
			} else {
				out += text.slice(i + 1, close);
				i = end + 1;
			}
		} else {
			out += c;
			i += 1;
		}
	}
	return out;
}

function prose(text: string): HoverLine {
	return { text, kind: LineKind.Prose, block: -1, at: 0 };
}

function wrapped(text: string, width: int32, out: HoverLine[]): void {
	let line = "";
	for (const word of text.split(" ")) {
		if (word.length == 0) { continue; }
		if (line.length > 0 && line.length + 1 + word.length > width) {
			out.push(prose(line));
			line = "";
		}
		line = line.length == 0 ? word : `${line} ${word}`;
		while (line.length > width) {
			out.push(prose(line.slice(0, width)));
			line = line.slice(width);
		}
	}
	out.push(prose(line));
}

function rule(line: string): boolean {
	const t = line.trim();
	return t.length >= 3 && (t.replaceAll("-", "") == "" || t.replaceAll("*", "") == "" || t.replaceAll("_", "") == "");
}

export function hoverOf(markdown: string, width: int32): Hover {
	const lines: HoverLine[] = [];
	const blocks: CodeBlock[] = [];
	let fenced = false;
	const blank = (): boolean => lines.length == 0
		|| (lines[lines.length - 1].kind == LineKind.Prose && lines[lines.length - 1].text == "");
	for (const raw of markdown.split("\n")) {
		const line = raw.endsWith("\r") ? raw.slice(0, raw.length - 1) : raw;
		const opening = line.trimStart();
		if (opening.startsWith(FENCE)) {
			fenced = !fenced;
			if (fenced) { blocks.push({ language: opening.slice(FENCE.length).trim(), source: "" }); }
			continue;
		}
		if (fenced) {
			const block = (blocks.length as int32) - 1;
			if (blocks[block].source.byteLength > 0) { blocks[block].source += "\n"; }
			let code = line.replaceAll("\t", TAB_SPACES);
			let at = blocks[block].source.byteLength as int32;
			blocks[block].source += code;
			while (code.length > width) {
				const piece = code.slice(0, width);
				lines.push({ text: piece, kind: LineKind.Code, block, at });
				at += piece.byteLength as int32;
				code = code.slice(width);
			}
			lines.push({ text: code, kind: LineKind.Code, block, at });
		} else if (line.trim() == "") {
			if (!blank()) { lines.push(prose("")); }
		} else if (rule(line)) {
			lines.push({ text: "", kind: LineKind.Rule, block: -1, at: 0 });
		} else {
			let text = line.trim();
			while (text.startsWith("#")) { text = text.slice(1); }
			wrapped(inline(text.trim()), width, lines);
		}
	}
	while (lines.length > 0 && blank()) { lines.pop(); }
	return { lines, blocks };
}

test "fenced code keeps its lines and prose loses its markup" {
	const h = hoverOf("```ms\nfunction f(a: int32): void\n```\n\n---\n## Notes\nCalls **[g](file:///g.ms)** with `a`.", 40);
	const lines = h.lines;
	assert lines.length == 5;
	assert lines[0].kind == LineKind.Code && lines[0].text == "function f(a: int32): void";
	assert h.blocks.length == 1 && h.blocks[0].language == "ms" && h.blocks[0].source == lines[0].text;
	assert lines[1].kind == LineKind.Prose && lines[1].text == "";
	assert lines[2].kind == LineKind.Rule;
	assert lines[3].text == "Notes";
	assert lines[4].text == "Calls g with a.";
}

test "prose wraps at word boundaries and a long word or code line breaks at the width" {
	const h = hoverOf("one two three four\n```\nab\nabcdefghij\n```", 9);
	const lines = h.lines;
	assert lines.length == 6;
	assert lines[0].text == "one two";
	assert lines[1].text == "three";
	assert lines[2].text == "four";
	assert lines[3].text == "ab" && lines[3].at == 0;
	assert lines[4].text == "abcdefghi" && lines[4].at == 3;
	assert lines[5].text == "j" && lines[5].kind == LineKind.Code && lines[5].at == 12;
	assert h.blocks[0].source == "ab\nabcdefghij";
	const broken = hoverOf("abcdefghijk", 4).lines;
	assert broken.length == 3 && broken[2].text == "ijk";
}
