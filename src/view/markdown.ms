const FENCE = "```";
const TAB_SPACES = "    ";

export struct HoverLine {
	text: string;
	code: boolean;
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

function wrapped(text: string, width: int32, out: HoverLine[]): void {
	let line = "";
	for (const word of text.split(" ")) {
		if (word.length == 0) { continue; }
		if (line.length > 0 && line.length + 1 + word.length > width) {
			out.push({ text: line, code: false });
			line = "";
		}
		line = line.length == 0 ? word : `${line} ${word}`;
		while (line.length > width) {
			out.push({ text: line.slice(0, width), code: false });
			line = line.slice(width);
		}
	}
	out.push({ text: line, code: false });
}

function rule(line: string): boolean {
	const t = line.trim();
	return t.length >= 3 && (t.replaceAll("-", "") == "" || t.replaceAll("*", "") == "" || t.replaceAll("_", "") == "");
}

export function hoverLines(markdown: string, width: int32): HoverLine[] {
	const out: HoverLine[] = [];
	let fenced = false;
	const blank = (): boolean => out.length == 0 || (!out[out.length - 1].code && out[out.length - 1].text == "");
	for (const raw of markdown.split("\n")) {
		const line = raw.endsWith("\r") ? raw.slice(0, raw.length - 1) : raw;
		if (line.trimStart().startsWith(FENCE)) {
			fenced = !fenced;
			continue;
		}
		if (fenced) {
			let code = line.replaceAll("\t", TAB_SPACES);
			while (code.length > width) {
				out.push({ text: code.slice(0, width), code: true });
				code = code.slice(width);
			}
			out.push({ text: code, code: true });
		} else if (line.trim() == "") {
			if (!blank()) { out.push({ text: "", code: false }); }
		} else if (rule(line)) {
			out.push({ text: "─".repeat(width), code: false });
		} else {
			let text = line.trim();
			while (text.startsWith("#")) { text = text.slice(1); }
			wrapped(inline(text.trim()), width, out);
		}
	}
	while (out.length > 0 && blank()) { out.pop(); }
	return out;
}

test "fenced code keeps its lines and prose loses its markup" {
	const lines = hoverLines("```ms\nfunction f(a: int32): void\n```\n\n---\n## Notes\nCalls **[g](file:///g.ms)** with `a`.", 40);
	assert lines.length == 5;
	assert lines[0].code && lines[0].text == "function f(a: int32): void";
	assert !lines[1].code && lines[1].text == "";
	assert lines[2].text == "─".repeat(40);
	assert lines[3].text == "Notes";
	assert lines[4].text == "Calls g with a.";
}

test "prose wraps at word boundaries and a long word or code line breaks at the width" {
	const lines = hoverLines("one two three four\n```\nabcdefghij\n```", 9);
	assert lines.length == 5;
	assert lines[0].text == "one two";
	assert lines[1].text == "three";
	assert lines[2].text == "four";
	assert lines[3].text == "abcdefghi" && lines[4].text == "j" && lines[4].code;
	const broken = hoverLines("abcdefghijk", 4);
	assert broken.length == 3 && broken[2].text == "ijk";
}
