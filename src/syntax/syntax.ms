@passC("-I../../vendor/tree-sitter/include");
@passC("-I../../vendor/tree-sitter/src");
@compile("../../vendor/tree-sitter/src/lib.c");
@compile("../../vendor/tree-sitter-metascript/parser.c");
@compile("../../vendor/tree-sitter-metascript/scanner.c");
@include("./shim.h");
@compile("./shim.c");

import { Handle } from "std/ffi";
import { Document } from "../model/document";
import { HIGHLIGHTS } from "./highlights";
import { luaMatches } from "./luaPattern";
import { Tone } from "../view/tone";

extern function syntaxNew(query: Readonly<Span<uint8>>, out errorOffset: int32): Ptr<void> | null from "medicSyntaxNew";
extern function syntaxFree(syntax: Ptr<void>): void from "medicSyntaxFree";
extern function syntaxFill(syntax: Ptr<void>, bytes: Readonly<Span<uint8>>): void from "medicSyntaxFill";
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
extern function captureName(syntax: Ptr<void>, id: int32, buf: Span<uint8>): int64 from "medicSyntaxCaptureName";
extern function stringValue(syntax: Ptr<void>, id: int32, buf: Span<uint8>): int64 from "medicSyntaxStringValue";
extern function predicateSteps(syntax: Ptr<void>, pattern: int32, steps: Span<int32>): int64 from "medicSyntaxPredicates";
extern function highlight(syntax: Ptr<void>, from: int32, to: int32): void from "medicSyntaxHighlight";
extern function nextCapture(
	syntax: Ptr<void>,
	out start: int32,
	out end: int32,
	out capture: int32,
	out pattern: int32,
): int32 from "medicSyntaxNextCapture";
extern function matchCapture(syntax: Ptr<void>, capture: int32, out start: int32, out end: int32): int32
	from "medicSyntaxMatchCapture";

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
	while (to > byte + 1 && to < total && (doc.byteAt(to) & 0xC0) == 0x80) { to -= 1; }
	const text = doc.slice(byte, to);
	syntaxFill(syntax, text.asBytes());
}

function toneNames(): Map<string, Tone> {
	const m = new Map<string, Tone>();
	m.set("keyword", Tone.Keyword);
	m.set("include", Tone.Keyword);
	m.set("boolean", Tone.Number);
	m.set("function", Tone.Function);
	m.set("constructor", Tone.Type);
	m.set("function.builtin", Tone.Builtin);
	m.set("function.macro", Tone.Builtin);
	m.set("type", Tone.Type);
	m.set("string", Tone.String);
	m.set("number", Tone.Number);
	m.set("constant", Tone.Constant);
	m.set("constant.builtin", Tone.Number);
	m.set("comment", Tone.Comment);
	m.set("operator", Tone.Operator);
	m.set("punctuation", Tone.Punctuation);
	m.set("variable", Tone.Variable);
	m.set("variable.parameter", Tone.Parameter);
	m.set("variable.member", Tone.Property);
	m.set("property", Tone.Property);
	m.set("variable.builtin", Tone.Builtin);
	m.set("tag", Tone.Tag);
	m.set("attribute", Tone.Attribute);
	m.set("label", Tone.Attribute);
	m.set("extern", Tone.Attribute);
	m.set("emit", Tone.Attribute);
	m.set("target", Tone.Attribute);
	m.set("comptime", Tone.Attribute);
	m.set("compile", Tone.Attribute);
	return m;
}

export function toneOf(names: Map<string, Tone>, capture: string): Tone {
	let key = capture;
	while (true) {
		const t = names.get(key);
		if (t !== undefined) { return t as Tone; }
		const dot = key.lastIndexOf(".");
		if (dot < 0) { return Tone.Plain; }
		key = key.slice(0, dot);
	}
}

enum Test {
	AnyOf,
	LuaMatch,
	Eq,
}

struct Check {
	test: Test;
	negated: boolean;
	capture: int32;
	values: string[];
}

export class Syntax {
	private handle: Ptr<void>;
	private parsed: int32;
	private tones: Tone[];
	private checks: Check[][];

	constructor() {
		let offset = 0;
		const h = syntaxNew(HIGHLIGHTS.asBytes(), offset);
		if (h === null) { throw new Error(`Syntax: the highlight query does not compile at byte ${offset}`); }
		this.handle = h as Ptr<void>;
		this.parsed = -1;
		const names = toneNames();
		this.tones = [];
		for (let id = 0; id < captureCount(this.handle); id++) { this.tones.push(toneOf(names, this.text(id, true))); }
		this.checks = [];
		for (let p = 0; p < patternCount(this.handle); p++) { this.checks.push(this.checksOf(p)); }
	}

	close(): void { syntaxFree(this.handle); }

	private text(id: int32, capture: boolean): string {
		let buf: Vec<uint8> = new Array(64);
		let n = capture ? captureName(this.handle, id, buf) : stringValue(this.handle, id, buf);
		if (n > (buf.length as int64)) {
			buf = new Array(n as int32);
			n = capture ? captureName(this.handle, id, buf) : stringValue(this.handle, id, buf);
		}
		return buf[0..(n as int32)].asString();
	}

	private checksOf(pattern: int32): Check[] {
		let steps: Vec<int32> = new Array(256);
		let n = predicateSteps(this.handle, pattern, steps);
		if (n > (steps.length as int64)) {
			steps = new Array(n as int32);
			n = predicateSteps(this.handle, pattern, steps);
		}
		const checks: Check[] = [];
		let from = 0;
		for (let i = 0; i < (n as int32); i += 2) {
			if (steps[i] == STEP_DONE) {
				checks.push(this.checkOf(pattern, steps, from, i));
				from = i + 2;
			}
		}
		return checks;
	}

	private checkOf(pattern: int32, steps: Vec<int32>, from: int32, to: int32): Check {
		const name = this.text(steps[from + 1], false);
		const negated = name.startsWith("not-");
		const op = negated ? name.slice(4) : name;
		const test = op == "any-of?" ? Test.AnyOf : op == "lua-match?" ? Test.LuaMatch : op == "eq?" ? Test.Eq : -1;
		if (test < 0) { throw new Error(`Syntax: query pattern ${pattern} uses #${name}, which medic does not evaluate`); }
		if (to - from < 6 || steps[from + 2] != STEP_CAPTURE) {
			throw new Error(`Syntax: query pattern ${pattern}: #${name} needs a capture, then a value`);
		}
		const values: string[] = [];
		for (let k = from + 4; k < to; k += 2) {
			if (steps[k] == STEP_CAPTURE) { throw new Error(`Syntax: query pattern ${pattern}: #${name} compares two captures`); }
			values.push(this.text(steps[k + 1], false));
		}
		return { test: test as Test, negated, capture: steps[from + 3], values };
	}

	sync(doc: Document): void {
		if (doc.version() == this.parsed) { return; }
		const changes = doc.changesSince(this.parsed);
		if (changes === null) { syntaxForget(this.handle); }
		else {
			for (const c of changes) {
				syntaxEdit(
					this.handle,
					c.change.from,
					c.change.from + c.change.removed,
					c.change.from + c.change.inserted,
					c.start.line,
					c.start.column,
					c.oldEnd.line,
					c.oldEnd.column,
					c.newEnd.line,
					c.newEnd.column,
				);
			}
		}
		if (syntaxParse(this.handle, Handle.borrow(doc).ptr) != 0) { throw new Error("Syntax.sync: tree-sitter returned no tree"); }
		this.parsed = doc.version();
	}

	private passes(doc: Document, pattern: int32): boolean {
		for (const c of this.checks[pattern]) {
			let start = 0;
			let end = 0;
			if (matchCapture(this.handle, c.capture, start, end) == 0) { continue; }
			const text = doc.slice(start, end);
			let hit = false;
			if (c.test == Test.AnyOf) {
				for (const v of c.values) { if (v == text) { hit = true; } }
			} else if (c.test == Test.LuaMatch) {
				hit = luaMatches(text, c.values[0]);
			} else {
				hit = text == c.values[0];
			}
			if (hit == c.negated) { return false; }
		}
		return true;
	}

	tonesIn(doc: Document, from: int32, to: int32): Tone[] {
		this.sync(doc);
		const tones: Tone[] = [];
		const widths: int32[] = [];
		const patterns: int32[] = [];
		for (let i = from; i < to; i++) {
			tones.push(Tone.Plain);
			widths.push(0);
			patterns.push(0);
		}
		highlight(this.handle, from, to);
		let start = 0;
		let end = 0;
		let capture = 0;
		let pattern = 0;
		while (nextCapture(this.handle, start, end, capture, pattern) != 0) {
			const tone = this.tones[capture];
			if (tone == Tone.Plain || !this.passes(doc, pattern)) { continue; }
			const width = end - start;
			for (let i = Math.max(start, from); i < Math.min(end, to); i++) {
				const k = i - from;
				if (widths[k] == 0 || width < widths[k] || (width == widths[k] && pattern >= patterns[k])) {
					tones[k] = tone;
					widths[k] = width;
					patterns[k] = pattern;
				}
			}
		}
		return tones;
	}
}

test "the grammar covers the MetaScript file types" {
	assert covers("src/app/app.ms");
	assert covers("a.b/c.jms");
	assert !covers("notes.md");
	assert !covers("Makefile");
	assert !covers("ms");
}

test "keywords, strings, numbers and comments get their tones" {
	const doc = new Document("const x = \"hi\"; // c\nlet n = 42;");
	const s = new Syntax();
	const tones = s.tonesIn(doc, 0, doc.length());
	assert tones[0] == Tone.Keyword;
	assert tones[10] == Tone.String;
	assert tones[16] == Tone.Comment;
	assert tones[29] == Tone.Number;
	s.close();
}

test "a template string is a string around its substitutions" {
	const doc = new Document("const t = `a ${b} c`;");
	const s = new Syntax();
	const tones = s.tonesIn(doc, 0, doc.length());
	assert tones[10] == Tone.String;
	assert tones[11] == Tone.String;
	assert tones[15] != Tone.String;
	assert tones[18] == Tone.String;
	s.close();
}

test "a predicate decides between two captures of one identifier" {
	const doc = new Document("Point; MAX_SIZE; value;");
	const s = new Syntax();
	const tones = s.tonesIn(doc, 0, doc.length());
	assert tones[0] == Tone.Type;
	assert tones[7] == Tone.Constant;
	assert tones[17] != Tone.Type && tones[17] != Tone.Constant;
	s.close();
}

test "an edit reparses incrementally and keeps tones right after it" {
	const doc = new Document("let a = 1;\nlet b = 2;");
	const s = new Syntax();
	const _first = s.tonesIn(doc, 0, doc.length());
	const _e = doc.splice({ from: 11, to: 14, text: "const" });
	const tones = s.tonesIn(doc, 11, doc.length());
	assert tones[0] == Tone.Keyword;
	assert tones[4] == Tone.Keyword;
	assert tones[10] == Tone.Number;
	s.close();
}
