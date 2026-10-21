@passC("-I../../vendor/tree-sitter/include");
@passC("-I../../vendor/tree-sitter/src");
@compile("../../vendor/tree-sitter/src/lib.c");
@compile("../../vendor/tree-sitter-metascript/parser.c");
@compile("../../vendor/tree-sitter-metascript/scanner.c");
@include("./shim.h");
@compile("./shim.c");

import { Handle } from "std/ffi";
import { Document } from "../model/document";
import { Ancestor, Expander, SyntaxNode } from "../model/expand";
import { Editor } from "../model/editor";
import { single } from "../model/selection";
import { isTrail } from "../text/clusters";
import { HIGHLIGHTS } from "./highlights";
import { luaMatches } from "./luaPattern";
import { Tone } from "../view/tone";

extern function syntaxNew(query: Readonly<Span<uint8>>, out errorOffset: int32): Ptr<void> | null
	from "medicSyntaxNew";
extern function syntaxFree(syntax: Ptr<void>): void from "medicSyntaxFree";
extern function syntaxFill(syntax: Ptr<void>, bytes: Readonly<Span<uint8>>): void
	from "medicSyntaxFill";
extern function syntaxForget(syntax: Ptr<void>): void from "medicSyntaxForget";
extern function syntaxEdit(
	syntax: Ptr<void>,
	start: int32,
	oldEnd: int32,
	newEnd: int32,
	startRow: int32,
	startColumn: int32,
	oldEndRow: int32,
	oldEndColumn: int32,
	newEndRow: int32,
	newEndColumn: int32,
): void from "medicSyntaxEdit";
extern function syntaxParse(syntax: Ptr<void>, source: Ptr<void>): int32 from "medicSyntaxParse";
extern function captureCount(syntax: Ptr<void>): int32 from "medicSyntaxCaptureCount";
extern function patternCount(syntax: Ptr<void>): int32 from "medicSyntaxPatternCount";
extern function copyCaptureName(syntax: Ptr<void>, id: int32, into: Span<uint8>): int64
	from "medicSyntaxCaptureName";
extern function copyStringValue(syntax: Ptr<void>, id: int32, into: Span<uint8>): int64
	from "medicSyntaxStringValue";
extern function copyPredicateSteps(syntax: Ptr<void>, pattern: int32, into: Span<int32>): int64
	from "medicSyntaxPredicates";
extern function highlight(syntax: Ptr<void>, from: int32, to: int32): void
	from "medicSyntaxHighlight";
extern function nextCapture(
	syntax: Ptr<void>,
	out start: int32,
	out end: int32,
	out capture: int32,
	out pattern: int32,
): int32 from "medicSyntaxNextCapture";
extern function matchCapture(
	syntax: Ptr<void>,
	capture: int32,
	out start: int32,
	out end: int32,
): int32 from "medicSyntaxMatchCapture";
extern function copyAncestor(
	syntax: Ptr<void>,
	from: int32,
	to: int32,
	out start: int32,
	out end: int32,
	out named: int32,
	into: Span<uint8>,
): int64 from "medicSyntaxAncestor";

const CHUNK: int32 = 4096;
const STEP_DONE: int32 = 0;
const STEP_CAPTURE: int32 = 1;
const FILE_TYPES = ["ms", "cms", "jms", "ems", "wms", "rms"];

export function covers(path: string): boolean {
	const dot = path.lastIndexOf(".");
	return dot >= 0 && FILE_TYPES.includes(path.slice(dot + 1));
}

@exportName("medicSyntaxRead")
function read(source: Ptr<void>, syntax: Ptr<void>, byte: int32): void {
	const doc = Handle.at<Document>(source).value();
	const total = doc.length();
	if (byte >= total) { return; }
	let to = Math.min(total, byte + CHUNK);
	while (to > byte + 1 && to < total && isTrail(doc.byteAt(to))) { to -= 1; }
	const text = doc.slice(byte, to);
	syntaxFill(syntax, text.asBytes());
}

function toneNamed(name: string): Tone {
	return match (name) {
		"keyword" | "include" => Tone.Keyword,
		"boolean" | "number" | "constant.builtin" => Tone.Number,
		"function" => Tone.Function,
		"constructor" | "type" => Tone.Type,
		"function.builtin" | "function.macro" | "variable.builtin" => Tone.Builtin,
		"string" => Tone.String,
		"constant" => Tone.Constant,
		"comment" => Tone.Comment,
		"operator" => Tone.Operator,
		"punctuation" => Tone.Punctuation,
		"variable" => Tone.Variable,
		"variable.parameter" => Tone.Parameter,
		"variable.member" | "property" => Tone.Property,
		"tag" => Tone.Tag,
		"attribute" | "label" | "extern" | "emit" |
			"target" | "comptime" | "compile" => Tone.Attribute,
		_ => Tone.Plain,
	};
}

export function toneOf(capture: string): Tone {
	const tone = toneNamed(capture);
	const dot = capture.lastIndexOf(".");
	return tone != Tone.Plain || dot < 0 ? tone : toneOf(capture.slice(0, dot));
}

enum Predicate {
	AnyOf,
	LuaMatch,
	Eq,
}

struct Check {
	predicate: Predicate;
	negated: boolean;
	capture: int32;
	values: string[];
}

export class Syntax {
	private handle: Ptr<void>;
	private parsed: int32;
	private tones: Vec<Tone>;
	private checks: Vec<Check[]>;

	constructor() {
		let offset = 0;
		const handle = syntaxNew(HIGHLIGHTS.asBytes(), out offset);
		if (handle === null) {
			throw new Error(`Syntax: the highlight query does not compile at byte ${offset}`);
		}
		this.handle = handle as Ptr<void>;
		this.parsed = -1;
		this.tones = [];
		for (let id = 0; id < captureCount(this.handle); id++) {
			this.tones.push(toneOf(this.text((into) => copyCaptureName(this.handle, id, into))));
		}
		this.checks = [];
		for (let pattern = 0; pattern < patternCount(this.handle); pattern++) {
			this.checks.push(this.checksOf(pattern));
		}
	}

	close(): void { syntaxFree(this.handle); }

	private text(copy: (into: Span<uint8>) => int64): string {
		let bytes: Vec<uint8> = new Array(64);
		let length = copy(bytes);
		if (length > bytes.length) {
			bytes = new Array(length as int32);
			length = copy(bytes);
		}
		return bytes[0..(length as int32)].asString();
	}

	private stringValue(id: int32): string {
		return this.text((into) => copyStringValue(this.handle, id, into));
	}

	private checksOf(pattern: int32): Check[] {
		let steps: Vec<int32> = new Array(256);
		let length = copyPredicateSteps(this.handle, pattern, steps);
		if (length > steps.length) {
			steps = new Array(length as int32);
			length = copyPredicateSteps(this.handle, pattern, steps);
		}
		const checks: Check[] = [];
		let from = 0;
		for (let i = 0; i < (length as int32); i += 2) {
			if (steps[i] == STEP_DONE) {
				checks.push(this.checkOf(pattern, steps[from..i]));
				from = i + 2;
			}
		}
		return checks;
	}

	private checkOf(pattern: int32, steps: Readonly<Span<int32>>): Check {
		const name = this.stringValue(steps[1]);
		const negated = name.startsWith("not-");
		const predicate = match (negated ? name.slice(4) : name) {
			"any-of?" => Predicate.AnyOf,
			"lua-match?" => Predicate.LuaMatch,
			"eq?" => Predicate.Eq,
			_ => {
				throw new Error(
					`Syntax: query pattern ${pattern} uses #${name}, which medic does not evaluate`,
				);
			},
		};
		if (steps.length < 6 || steps[2] != STEP_CAPTURE) {
			throw new Error(
				`Syntax: query pattern ${pattern}: #${name} needs a capture, then a value`,
			);
		}
		const values: string[] = [];
		for (let k = 4; k < steps.length; k += 2) {
			if (steps[k] == STEP_CAPTURE) {
				throw new Error(`Syntax: query pattern ${pattern}: #${name} compares two captures`);
			}
			values.push(this.stringValue(steps[k + 1]));
		}
		return { predicate, negated, capture: steps[3], values };
	}

	sync(doc: Document): void {
		if (doc.version() == this.parsed) { return; }
		const changes = doc.changesSince(this.parsed);
		if (changes === null) {
			syntaxForget(this.handle);
		} else {
			for (const logged of changes) {
				const change = logged.change;
				syntaxEdit(
					this.handle,
					change.from,
					change.from + change.removed,
					change.from + change.inserted,
					logged.start.line,
					logged.start.column,
					logged.oldEnd.line,
					logged.oldEnd.column,
					logged.newEnd.line,
					logged.newEnd.column,
				);
			}
		}
		if (syntaxParse(this.handle, Handle.borrow(doc).ptr) != 0) {
			throw new Error("Syntax.sync: tree-sitter returned no tree");
		}
		this.parsed = doc.version();
	}

	private passes(doc: Document, pattern: int32): boolean {
		for (const check of this.checks[pattern]) {
			let start = 0;
			let end = 0;
			if (matchCapture(this.handle, check.capture, out start, out end) == 0) { continue; }
			const text = doc.slice(start, end);
			const hit = match (check.predicate) {
				Predicate.AnyOf => check.values.includes(text),
				Predicate.LuaMatch => luaMatches(text, check.values[0]),
				Predicate.Eq => text == check.values[0],
			};
			if (hit == check.negated) { return false; }
		}
		return true;
	}

	tonesIn(doc: Document, from: int32, to: int32): Tone[] {
		this.sync(doc);
		const tones: Tone[] = [];
		for (let i = from; i < to; i++) { tones.push(Tone.Plain); }
		let widths: Vec<int32> = new Array(tones.length);
		let patterns: Vec<int32> = new Array(tones.length);
		highlight(this.handle, from, to);
		let start = 0;
		let end = 0;
		let capture = 0;
		let pattern = 0;
		while (nextCapture(this.handle, out start, out end, out capture, out pattern) != 0) {
			const tone = this.tones[capture];
			if (tone == Tone.Plain || !this.passes(doc, pattern)) { continue; }
			const width = end - start;
			for (let i = Math.max(start, from); i < Math.min(end, to); i++) {
				const k = i - from;
				const narrower = widths[k] == 0 || width < widths[k];
				if (narrower || (width == widths[k] && pattern >= patterns[k])) {
					tones[k] = tone;
					widths[k] = width;
					patterns[k] = pattern;
				}
			}
		}
		return tones;
	}

	ancestor(doc: Document, from: int32, to: int32): SyntaxNode | null {
		this.sync(doc);
		let start = 0;
		let end = 0;
		let named = 0;
		let kind: Vec<uint8> = new Array(64);
		let length = copyAncestor(this.handle, from, to, out start, out end, out named, kind);
		if (length < 0) { return null; }
		if (length > kind.length) {
			kind = new Array(length as int32);
			length = copyAncestor(this.handle, from, to, out start, out end, out named, kind);
		}
		const name = kind[0..(length as int32)].asString();
		return { from: start, to: end, named: named != 0, kind: name };
	}

	ancestors(doc: Document): Ancestor {
		return (from: int32, to: int32): SyntaxNode | null => this.ancestor(doc, from, to);
	}
}

test "the grammar covers the MetaScript file types" {
	assert covers("src/app/app.ms");
	assert covers("a.b/c.jms");
	assert !covers("notes.md");
	assert !covers("Makefile");
	assert !covers("ms");
}

test "a capture takes the tone of its longest known name" {
	assert toneOf("keyword.conditional.ternary") == Tone.Keyword;
	assert toneOf("constant.builtin") == Tone.Number;
	assert toneOf("constant") == Tone.Constant;
	assert toneOf("variable.parameter.builtin") == Tone.Parameter;
	assert toneOf("punctuation.bracket") == Tone.Punctuation;
	assert toneOf("spell") == Tone.Plain;
}

test "keywords, strings, numbers and comments get their tones" {
	const doc = new Document("const x = \"hi\"; // c\nlet n = 42;");
	const syntax = new Syntax();
	const tones = syntax.tonesIn(doc, 0, doc.length());
	assert tones[0] == Tone.Keyword;
	assert tones[10] == Tone.String;
	assert tones[16] == Tone.Comment;
	assert tones[29] == Tone.Number;
	syntax.close();
}

test "a template string is a string around its substitutions" {
	const doc = new Document("const t = `a ${b} c`;");
	const syntax = new Syntax();
	const tones = syntax.tonesIn(doc, 0, doc.length());
	assert tones[10] == Tone.String;
	assert tones[11] == Tone.String;
	assert tones[15] != Tone.String;
	assert tones[18] == Tone.String;
	syntax.close();
}

test "a predicate decides between two captures of one identifier" {
	const doc = new Document("Point; MAX_SIZE; value;");
	const syntax = new Syntax();
	const tones = syntax.tonesIn(doc, 0, doc.length());
	assert tones[0] == Tone.Type;
	assert tones[7] == Tone.Constant;
	assert tones[17] != Tone.Type && tones[17] != Tone.Constant;
	syntax.close();
}

test "an edit reparses incrementally and keeps tones right after it" {
	const doc = new Document("let a = 1;\nlet b = 2;");
	const syntax = new Syntax();
	const _first = syntax.tonesIn(doc, 0, doc.length());
	const _e = doc.splice({ from: 11, to: 14, text: "const" });
	const tones = syntax.tonesIn(doc, 11, doc.length());
	assert tones[0] == Tone.Keyword;
	assert tones[4] == Tone.Keyword;
	assert tones[10] == Tone.Number;
	syntax.close();
}

function grownTexts(text: string, at: int32): string[] {
	const e = new Editor(new Document(text));
	e.select(single(at));
	const syntax = new Syntax();
	const expander = new Expander(syntax.ancestors(e.doc));
	const texts: string[] = [];
	while (expander.grow(e)) {
		const s = e.selections.ranges[0];
		texts.push(e.doc.slice(s.start(), s.end()));
	}
	syntax.close();
	return texts;
}

test "growing walks out one named node at a time and stops below the whole program" {
	const texts = grownTexts("const total = add(first, second) + 1;", 27);
	assert texts.join("|") == "second|(first, second)|add(first, second)|add(first, second) + 1|" +
		"const total = add(first, second) + 1;";
}

test "a caret takes the token after it, or the one before it across a space" {
	assert grownTexts("f(a);", 2)[0] == "a";
	assert grownTexts("f(a );", 3)[0] == "a";
	assert grownTexts("f(a);", 3)[0] == "(a)";
}

test "inside a string the word under the caret comes first, by bytes" {
	const texts = grownTexts("let s = \"hé wörld\";
", 14);
	assert texts[0] == "wörld";
	assert texts[1] == "\"hé wörld\"";
}

test "shrinking after growing over the real tree returns each earlier selection" {
	const e = new Editor(new Document("g(h(x));"));
	e.select(single(4));
	const syntax = new Syntax();
	const expander = new Expander(syntax.ancestors(e.doc));
	for (let i = 0; i < 5; i++) { assert expander.grow(e); }
	assert e.doc.slice(e.selections.ranges[0].start(), e.selections.ranges[0].end()) == "g(h(x))";
	assert expander.shrink(e);
	assert expander.shrink(e);
	assert e.doc.slice(e.selections.ranges[0].start(), e.selections.ranges[0].end()) == "h(x)";
	syntax.close();
}
