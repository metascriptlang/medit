import { Document } from "./document";

export const DEFAULT_INDENT = "    ";
const LINES_LOOKED: int32 = 10000;
const LINE_LOOK: int32 = 65536;
const SPACE: int32 = 32;
const TAB: int32 = 9;
const COMMA: int32 = 44;
const MAX_GUESS: int32 = 8;
const GUESSES: int32[] = [2, 4, 6, 8, 3, 5, 7];

interface Step {
	spaces: int32;
	alignment: boolean;
}

function stepBetween(a: string, aIndent: int32, aLast: int32, b: string, bIndent: int32): Step {
	let i = 0;
	while (i < aIndent && i < bIndent && a.byteAt(i) == b.byteAt(i)) { i += 1; }
	let aSpaces = 0;
	let aTabs = 0;
	for (let j = i; j < aIndent; j++) {
		if (a.byteAt(j) == SPACE) { aSpaces += 1; } else { aTabs += 1; }
	}
	let bSpaces = 0;
	let bTabs = 0;
	for (let j = i; j < bIndent; j++) {
		if (b.byteAt(j) == SPACE) { bSpaces += 1; } else { bTabs += 1; }
	}
	if ((aSpaces > 0 && aTabs > 0) || (bSpaces > 0 && bTabs > 0)) { return { spaces: 0, alignment: false }; }
	const tabs = Math.abs(aTabs - bTabs) as int32;
	const spaces = Math.abs(aSpaces - bSpaces) as int32;
	if (tabs == 0) {
		const alignment = spaces > 0 && bSpaces >= 1 && bSpaces - 1 < a.byteLength && bSpaces < b.byteLength
			&& b.byteAt(bSpaces) != SPACE && a.byteAt(bSpaces - 1) == SPACE && aLast == COMMA;
		return { spaces, alignment };
	}
	return { spaces: spaces % tabs == 0 ? (spaces / tabs) as int32 : 0, alignment: false };
}

export function guessIndent(doc: Document): string {
	const lines = Math.min(doc.lineCount(), LINES_LOOKED);
	let tabbed = 0;
	let spaced = 0;
	let previous = "";
	let previousIndent = 0;
	let previousLast = 0;
	const steps: int32[] = [0, 0, 0, 0, 0, 0, 0, 0, 0];
	for (let line = 0; line < lines; line++) {
		const from = doc.lineStart(line);
		const end = doc.lineEnd(line);
		const text = doc.slice(from, Math.min(end, from + LINE_LOOK));
		let indent = 0;
		let spaces = 0;
		let tabs = 0;
		while (indent < text.byteLength && (text.byteAt(indent) == SPACE || text.byteAt(indent) == TAB)) {
			if (text.byteAt(indent) == TAB) { tabs += 1; } else { spaces += 1; }
			indent += 1;
		}
		if (indent == text.byteLength) { continue; }
		if (tabs > 0) { tabbed += 1; } else if (spaces > 1) { spaced += 1; }
		const step = stepBetween(previous, previousIndent, previousLast, text, indent);
		if (step.alignment && step.spaces != DEFAULT_INDENT.byteLength) { continue; }
		if (step.spaces <= MAX_GUESS) { steps[step.spaces] += 1; }
		previous = text;
		previousIndent = indent;
		previousLast = doc.byteAt(end - 1);
	}
	if (tabbed > spaced) { return "\t"; }
	let size = DEFAULT_INDENT.byteLength;
	let score = 0;
	for (let k = 0; k < (GUESSES.length as int32); k++) {
		if (steps[GUESSES[k]] > score) {
			score = steps[GUESSES[k]];
			size = GUESSES[k];
		}
	}
	if (size == 4 && steps[4] > 0 && steps[2] > 0 && steps[2] * 3 >= steps[4] * 2) { size = 2; }
	return " ".repeat(size);
}

when (testBuild) {
	test "a document indented with tabs indents with a tab, one with spaces by its most frequent step" {
		assert guessIndent(new Document("f {\n\tg {\n\t\tx;\n\t}\n}\n")) == "\t";
		assert guessIndent(new Document("f {\n  g {\n    x;\n  }\n}\n")) == "  ";
		assert guessIndent(new Document("f {\n    g {\n        x;\n    }\n}\n")) == "    ";
		assert guessIndent(new Document("a:\n   b\n      c\n")) == "   ";
	}

	test "a document with no indented line takes the default, and ties between tabs and spaces too" {
		assert guessIndent(new Document("")) == DEFAULT_INDENT;
		assert guessIndent(new Document("a\nb\n")) == DEFAULT_INDENT;
		assert guessIndent(new Document("{\n\ta\n}\n{\n    b\n}\n")) == DEFAULT_INDENT;
	}

	test "lines aligned after a comma do not count as a step, and two wins over four when nearly as frequent" {
		assert guessIndent(new Document("const a = 1,\n      b = 2;\nif (x) {\n    y;\n}\n")) == "    ";
		assert guessIndent(new Document("a:\n  b:\n    c\n  d:\n    e\nf:\n  g\n")) == "  ";
	}
}
