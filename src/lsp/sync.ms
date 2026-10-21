import { Rope } from "../text/rope";
import { Bias, Document, mapOffset } from "../model/document";
import { Position, Range, offsetIn, offsetOf, positionIn } from "./position";

const KEPT_VERSIONS: int32 = 10;

export enum SyncKind {
	None = 0,
	Full = 1,
	Incremental = 2,
}

struct TextDocumentItem {
	uri: string;
	languageId: string;
	version: int32;
	text: string;
}

struct DidOpen {
	textDocument: TextDocumentItem;
}

struct VersionedId {
	uri: string;
	version: int32;
}

struct RangeChange {
	range: Range;
	text: string;
}

struct WholeChange {
	text: string;
}

struct DidChangeRanges {
	textDocument: VersionedId;
	contentChanges: RangeChange[];
}

struct DidChangeWhole {
	textDocument: VersionedId;
	contentChanges: WholeChange[];
}

struct DocumentId {
	uri: string;
}

struct DidSave {
	textDocument: DocumentId;
}

struct DidSaveWithText {
	textDocument: DocumentId;
	text: string;
}

struct DidClose {
	textDocument: DocumentId;
}

struct Sent {
	version: int32;
	text: Rope;
	at: int32;
}

function mapped(doc: Document, text: Rope, at: int32, p: Position, bias: Bias): int32 | null {
	const logged = doc.changesSince(at);
	if (logged === null) { return null; }
	let offset = offsetIn(text, p);
	for (const c of logged) { offset = mapOffset(offset, c.change, bias); }
	return offset;
}

export class DocumentSync {
	readonly uri: string;
	private languageId: string;
	private crlf: boolean;
	private version: int32 = 0;
	private sentAt: int32 = 0;
	private shadow: Rope;
	private kept: Sent[] = [];

	constructor(uri: string, languageId: string, doc: Document) {
		this.uri = uri;
		this.languageId = languageId;
		this.crlf = doc.usesCrlf();
		this.shadow = doc.snapshot();
		this.sentAt = doc.version();
	}

	lspVersion(): int32 { return this.version; }

	private keep(): void {
		this.kept.push({ version: this.version, text: this.shadow.copy(), at: this.sentAt });
		if ((this.kept.length as int32) > KEPT_VERSIONS) { this.kept.shift(); }
	}

	private wire(text: string): string {
		return this.crlf ? text.replaceAll("\n", "\r\n") : text;
	}

	opened(doc: Document): string {
		this.shadow = doc.snapshot();
		this.sentAt = doc.version();
		this.kept = [];
		this.keep();
		const params: DidOpen = {
			textDocument: { uri: this.uri, languageId: this.languageId, version: this.version, text: this.wire(doc.text()) },
		};
		return JSON.stringify<DidOpen>(params);
	}

	changed(doc: Document, kind: SyncKind): string | null {
		if (kind == SyncKind.None || doc.version() == this.sentAt) { return null; }
		const logged = kind == SyncKind.Incremental ? doc.changesSince(this.sentAt) : null;
		this.version += 1;
		this.sentAt = doc.version();
		const id: VersionedId = { uri: this.uri, version: this.version };
		if (logged === null) {
			this.shadow = doc.snapshot();
			this.keep();
			const whole: DidChangeWhole = { textDocument: id, contentChanges: [{ text: this.wire(doc.text()) }] };
			return JSON.stringify<DidChangeWhole>(whole);
		}
		const changes: RangeChange[] = [];
		for (const c of logged) {
			const from = c.change.from;
			const to = from + c.change.removed;
			changes.push({
				range: { start: positionIn(this.shadow, from), end: positionIn(this.shadow, to) },
				text: this.wire(c.text),
			});
			this.shadow.replace(from, to, c.text);
		}
		this.keep();
		const ranged: DidChangeRanges = { textDocument: id, contentChanges: changes };
		return JSON.stringify<DidChangeRanges>(ranged);
	}

	offsetNow(doc: Document, p: Position, bias: Bias): int32 {
		const found = mapped(doc, this.shadow, this.sentAt, p, bias);
		return found === null ? doc.offsetOf(p) : found as int32;
	}

	keeps(version: int32): boolean {
		for (const k of this.kept) {
			if (k.version == version) { return true; }
		}
		return false;
	}

	offsetAt(doc: Document, version: int32 | null, p: Position, bias: Bias): int32 | null {
		if (version === null) { return this.offsetNow(doc, p, bias); }
		for (const k of this.kept) {
			if (k.version == version) { return mapped(doc, k.text, k.at, p, bias); }
		}
		return null;
	}

	saved(doc: Document, includeText: boolean): string {
		const id: DocumentId = { uri: this.uri };
		if (includeText) {
			const withText: DidSaveWithText = { textDocument: id, text: this.wire(doc.text()) };
			return JSON.stringify<DidSaveWithText>(withText);
		}
		const params: DidSave = { textDocument: id };
		return JSON.stringify<DidSave>(params);
	}

	closed(): string {
		const params: DidClose = { textDocument: { uri: this.uri } };
		return JSON.stringify<DidClose>(params);
	}
}

when (testBuild) {
	function applied(text: string, params: string): string {
		const parsed = JSON.parseValue(params);
		let out = text;
		if (!parsed.ok) { return parsed.error; }
		if (parsed.ok) {
			const changes = parsed.value.getDynamicField("contentChanges");
			for (let i = 0; i < changes.length(); i++) {
				const c = changes.at(i);
				const range = c.getDynamicField("range");
				const inserted = c.getDynamicField("text").asString();
				if (range.kind == JsonKind.Null) {
					out = inserted;
					continue;
				}
				const d = new Document(out);
				const start = range.getDynamicField("start");
				const end = range.getDynamicField("end");
				const from = d.lineStart(start.getDynamicField("line").asInt32())
					+ start.getDynamicField("character").asInt32();
				const to = d.lineStart(end.getDynamicField("line").asInt32())
					+ end.getDynamicField("character").asInt32();
				out = out.byteSlice(0, from) + inserted + out.byteSlice(to, out.byteLength);
			}
		}
		return out;
	}

	test "incremental changes, applied in order, rebuild the document the server holds" {
		const d = new Document("one\ntwo\nthree\n");
		const sync = new DocumentSync("file:///a.ms", "metascript", d);
		const open = sync.opened(d);
		assert open.includes("\"version\":0") && open.includes("\"languageId\":\"metascript\"");
		const _a = d.splice({ from: 4, to: 7, text: "TWO\nmore" });
		const _b = d.splice({ from: 0, to: 0, text: "zero\n" });
		const _c = d.splice({ from: 10, to: 16, text: "" });
		const params = sync.changed(d, SyncKind.Incremental);
		assert params !== null;
		if (params !== null) {
			assert params.includes("\"version\":1");
			assert applied("one\ntwo\nthree\n", params) == d.text();
		}
		assert sync.changed(d, SyncKind.Incremental) === null;
		assert sync.lspVersion() == 1;
	}

	test "a full sync, or a log that no longer reaches back, sends the whole text" {
		const d = new Document("a\r\nb");
		const sync = new DocumentSync("file:///a.ms", "metascript", d);
		const _o = sync.opened(d);
		const _a = d.splice({ from: 1, to: 1, text: "\nc" });
		const full = sync.changed(d, SyncKind.Full);
		assert full !== null;
		if (full !== null) {
			assert full.includes("\"contentChanges\":[{\"text\":\"a\\r\\nc\\r\\nb\"}]");
			assert !full.includes("range");
		}
		const _b = d.splice({ from: 0, to: 0, text: "x" });
		assert sync.changed(d, SyncKind.None) === null;
		const ranged = sync.changed(d, SyncKind.Incremental);
		assert ranged !== null;
		if (ranged !== null) { assert ranged.includes("\"range\":{\"start\":{\"line\":0,\"character\":0}"); }
	}

	test "a position the server sent maps through edits made since" {
		const d = new Document("ab\ncd");
		const sync = new DocumentSync("file:///a.ms", "metascript", d);
		const _o = sync.opened(d);
		const _a = d.splice({ from: 0, to: 0, text: "zz\n" });
		assert sync.offsetNow(d, { line: 1, character: 1 }, Bias.Right) == 7;
		const _p = sync.changed(d, SyncKind.Incremental);
		assert sync.offsetNow(d, { line: 1, character: 1 }, Bias.Right) == 4;
	}

	test "a position from an older version reads that version's text, and a forgotten one is dropped" {
		const d = new Document("ab
cd");
		const sync = new DocumentSync("file:///a.ms", "metascript", d);
		const _o = sync.opened(d);
		const _a = d.splice({ from: 0, to: 0, text: "zz
" });
		const _p = sync.changed(d, SyncKind.Incremental);
		const _b = d.splice({ from: 0, to: 0, text: "y" });
		assert sync.offsetAt(d, 0, { line: 1, character: 1 }, Bias.Right) == 8;
		assert sync.offsetAt(d, 1, { line: 1, character: 1 }, Bias.Right) == 5;
		assert sync.offsetAt(d, null, { line: 1, character: 1 }, Bias.Right) == 5;
		for (let i = 0; i < 10; i++) {
			const _c = d.splice({ from: 0, to: 0, text: "w" });
			const _q = sync.changed(d, SyncKind.Incremental);
		}
		assert sync.offsetAt(d, 0, { line: 1, character: 1 }, Bias.Right) === null;
		assert sync.offsetAt(d, 11, { line: 0, character: 0 }, Bias.Right) == 0;
	}

	test "save and close name the document" {
		const d = new Document("x");
		const sync = new DocumentSync("file:///a.ms", "metascript", d);
		assert sync.saved(d, false) == "{\"textDocument\":{\"uri\":\"file:///a.ms\"}}";
		assert sync.saved(d, true).includes("\"text\":\"x\"");
		assert sync.closed() == "{\"textDocument\":{\"uri\":\"file:///a.ms\"}}";
	}
}
