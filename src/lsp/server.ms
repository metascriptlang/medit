import { Document, Edit, Bias } from "../model/document";
import { Diagnostic, Severity } from "../model/diagnostics";
import { Completion, snippetText, wordAround } from "../model/completion";
import { Parameter, Signature, SignatureAsk, SignatureHelp } from "../model/signatures";
import { Occurrence } from "../model/occurrences";
import { refined } from "../model/patch";
import { Client, NotificationHandler, Reply, failed, quoted } from "./client";
import { DocumentSync, SyncKind } from "./sync";
import { Position, Range, byteColumn, positionOf } from "./position";
import { isKind } from "./json";
import { TAB_SIZE } from "../text/clusters";

const CLIENT_CAPABILITIES = "{"
	+ "\"general\":{\"positionEncodings\":[\"utf-16\"]},"
	+ "\"textDocument\":{"
	+ "\"synchronization\":{\"didSave\":true},"
	+ "\"publishDiagnostics\":{\"versionSupport\":true,\"tagSupport\":{\"valueSet\":[1,2]}},"
	+ "\"hover\":{\"contentFormat\":[\"markdown\",\"plaintext\"]},"
	+ "\"definition\":{\"linkSupport\":true},"
	+ "\"completion\":{\"completionItem\":{\"snippetSupport\":false,\"insertReplaceSupport\":true,"
	+ "\"resolveSupport\":{\"properties\":[\"documentation\",\"detail\",\"additionalTextEdits\"]},"
	+ "\"documentationFormat\":[\"markdown\",\"plaintext\"],\"deprecatedSupport\":true,"
	+ "\"tagSupport\":{\"valueSet\":[1]}},"
	+ "\"contextSupport\":true,"
	+ "\"completionList\":{\"itemDefaults\":[\"editRange\",\"insertTextFormat\",\"data\"]}},"
	+ "\"signatureHelp\":{\"signatureInformation\":{\"documentationFormat\":[\"markdown\",\"plaintext\"],"
	+ "\"parameterInformation\":{\"labelOffsetSupport\":true},\"activeParameterSupport\":true},\"contextSupport\":true},"
	+ "\"formatting\":{},\"rangeFormatting\":{},\"documentHighlight\":{},\"rename\":{\"prepareSupport\":true}"
	+ "},"
	+ "\"workspace\":{\"configuration\":true},"
	+ "\"window\":{\"workDoneProgress\":false,\"showMessage\":{}}"
	+ "}";

const FENCE = "```";
const FORMATTING_OPTIONS = `{"tabSize":${TAB_SIZE},"insertSpaces":false,"trimTrailingWhitespace":true,`
	+ `"insertFinalNewline":true,"trimFinalNewlines":true}`;

export enum State {
	Starting,
	Ready,
	Stopped,
}

export struct Location {
	uri: string;
	range: Range;
}

export struct Span {
	from: int32;
	to: int32;
}

export struct Target {
	uri: string;
	range: Range;
	here: Span | null;
}

struct TextDocumentId {
	uri: string;
}

struct PositionParams {
	textDocument: TextDocumentId;
	position: Position;
}

function rangeOf(v: JsonValue): Range {
	const start = v.getDynamicField("start");
	const end = v.getDynamicField("end");
	return {
		start: { line: start.getDynamicField("line").asInt32(), character: start.getDynamicField("character").asInt32() },
		end: { line: end.getDynamicField("line").asInt32(), character: end.getDynamicField("character").asInt32() },
	};
}

function markedText(v: JsonValue): string {
	const text = v.asString();
	if (v.kind == JsonKind.String) { return text; }
	const language = v.getDynamicField("language").asString();
	const value = v.getDynamicField("value").asString();
	return language.byteLength > 0 ? FENCE + language + "\n" + value + "\n" + FENCE : value;
}

export function hoverText(contents: JsonValue): string {
	if (!isKind(contents, JsonKind.Array)) { return markedText(contents).trim(); }
	const parts: string[] = [];
	for (let i = 0; i < contents.length(); i++) {
		const part = markedText(contents.at(i)).trim();
		if (part.byteLength > 0) { parts.push(part); }
	}
	return parts.join("\n\n");
}

export function locationsOf(result: JsonValue): Location[] {
	const out: Location[] = [];
	const one = (v: JsonValue): void => {
		const target = v.getDynamicField("targetUri").asString();
		if (target.byteLength > 0) {
			out.push({ uri: target, range: rangeOf(v.getDynamicField("targetSelectionRange")) });
			return;
		}
		const uri = v.getDynamicField("uri").asString();
		if (uri.byteLength > 0) { out.push({ uri, range: rangeOf(v.getDynamicField("range")) }); }
	};
	if (isKind(result, JsonKind.Array)) {
		for (let i = 0; i < result.length(); i++) { one(result.at(i)); }
	} else {
		one(result);
	}
	return out;
}

const UNNECESSARY: int32 = 1;
const WRITE_HIGHLIGHT: int32 = 3;
const DEPRECATED: int32 = 1;
const SNIPPET: int32 = 2;
const INVOKED: int32 = 1;
const TRIGGER_CHARACTER: int32 = 2;

function present(v: JsonValue): boolean { return !isKind(v, JsonKind.Null); }

// A JSON object's text with one more field; `object` is the text of a non-empty object.
function withField(object: string, name: string, value: string): string {
	return object.byteSlice(0, (object.byteLength as int32) - 1) + `,${quoted(name)}:${value}}`;
}

// A parameter's label is either its text, found in the signature's label, or a UTF-16 range of it.
function parameterOf(label: string, p: JsonValue): Parameter {
	const l = p.getDynamicField("label");
	const doc = p.getDynamicField("documentation");
	const documentation = present(doc) ? documentationOf(doc) : "";
	if (isKind(l, JsonKind.Array) && l.length() == 2) {
		const a = l.at(0).asInt32(-1);
		const b = l.at(1).asInt32(-1);
		if (a < 0 || a >= b) { return { from: -1, to: -1, documentation }; }
		return { from: byteColumn(label, a), to: byteColumn(label, b), documentation };
	}
	const text = l.asString();
	const at = text.byteLength == 0 ? -1 : label.indexOf(text);
	if (at < 0) { return { from: -1, to: -1, documentation }; }
	const from = byteColumn(label, at as int32);
	return { from, to: from + (text.byteLength as int32), documentation };
}

function signatureOf(v: JsonValue, shared: JsonValue): Signature {
	const label = v.getDynamicField("label").asString();
	const list = v.getDynamicField("parameters");
	const parameters: Parameter[] = [];
	for (let i = 0; i < list.length(); i++) { parameters.push(parameterOf(label, list.at(i))); }
	const own = v.getDynamicField("activeParameter");
	const doc = v.getDynamicField("documentation");
	return {
		label,
		documentation: present(doc) ? documentationOf(doc) : "",
		parameters,
		active: present(own) ? own.asInt32(0) : shared.asInt32(0),
	};
}

export function documentationOf(v: JsonValue): string {
	if (isKind(v, JsonKind.String)) { return v.asString(); }
	const value = v.getDynamicField("value").asString();
	return v.getDynamicField("kind").asString() == "plaintext" ? plainMarkdown(value) : value;
}

const MARKUP = "\\`*[#-_";

// Plain text as markdown that shows it as written: its markup characters are escaped.
export function plainMarkdown(text: string): string {
	let out = "";
	const n = text.byteLength as int32;
	for (let k = 0; k < n; k++) {
		const c = text.byteSlice(k, k + 1);
		if (MARKUP.includes(c)) { out += "\\"; }
		out += c;
	}
	return out;
}

function tagged(tags: JsonValue, tag: int32): boolean {
	for (let i = 0; i < tags.length(); i++) {
		if (tags.at(i).asInt32() == tag) { return true; }
	}
	return false;
}

function severityOf(n: int32): Severity {
	return n == 1 ? Severity.Error : n == 2 ? Severity.Warning : n == 3 ? Severity.Information : Severity.Hint;
}

export class Server {
	private client: Client;
	private state: State = State.Starting;
	private queued: Array<[string, string]> = [];
	private sync: DocumentSync | null = null;
	private syncKind: SyncKind = SyncKind.Full;
	private saveText: boolean = false;
	private capabilities: JsonValue = jsonNull();

	constructor(write: (bytes: string) => void, complain: (message: string) => void) {
		this.client = new Client(write, complain);
		this.client.answer("workspace/configuration", (params: JsonValue): string => {
			const items = params.getDynamicField("items");
			const nulls: string[] = [];
			for (let i = 0; i < items.length(); i++) { nulls.push("null"); }
			return `[${nulls.join(",")}]`;
		});
		this.client.answer("client/registerCapability", (params: JsonValue): string => "null");
		this.client.answer("client/unregisterCapability", (params: JsonValue): string => "null");
		this.client.answer("window/workDoneProgress/create", (params: JsonValue): string => "null");
	}

	ready(): boolean { return this.state == State.Ready; }
	stopped(): boolean { return this.state == State.Stopped; }
	pending(): int32 { return this.client.pending(); }

	provides(capability: string): boolean {
		const v = this.capabilities.getDynamicField(capability);
		return !isKind(v, JsonKind.Null) && !(isKind(v, JsonKind.Bool) && !v.asBoolean());
	}

	triggers(provider: string, field: string): string[] {
		const list = this.capabilities.getDynamicField(provider).getDynamicField(field);
		const out: string[] = [];
		for (let i = 0; i < list.length(); i++) { out.push(list.at(i).asString()); }
		return out;
	}

	receive(chunk: string): void { this.client.receive(chunk); }

	on(method: string, handler: NotificationHandler): void { this.client.on(method, handler); }

	initialize(rootUri: string | null, processId: int32 | null, done: (error: string | null) => void): void {
		const root = rootUri === null ? "null" : JSON.stringify<string>(rootUri as string);
		const pid = processId === null ? "null" : `${processId as int32}`;
		const params = `{"processId":${pid},"rootUri":${root},"capabilities":${CLIENT_CAPABILITIES},`
			+ `"clientInfo":{"name":"medic"}}`;
		const _id = this.client.request("initialize", params, (r: Reply): void => {
			if (r.failed()) {
				this.state = State.Stopped;
				done(`initialize failed: ${r.message}`);
				return;
			}
			this.capabilities = r.result.getDynamicField("capabilities");
			this.readSync();
			this.state = State.Ready;
			this.client.notify("initialized", "{}");
			for (const [method, params] of this.queued) { this.client.notify(method, params); }
			this.queued = [];
			done(null);
		});
	}

	private readSync(): void {
		const sync = this.capabilities.getDynamicField("textDocumentSync");
		if (sync.kind == JsonKind.Int || sync.kind == JsonKind.Number) {
			this.syncKind = sync.asInt32() as SyncKind;
			return;
		}
		this.syncKind = sync.getDynamicField("change").asInt32(SyncKind.None as int32) as SyncKind;
		const save = sync.getDynamicField("save");
		this.saveText = save.getDynamicField("includeText").asBoolean(false);
	}

	private send(method: string, params: string): void {
		if (this.state == State.Ready) {
			this.client.notify(method, params);
		} else if (this.state == State.Starting) {
			this.queued.push([method, params]);
		}
	}

	open(doc: Document, uri: string, languageId: string): void {
		const sync = new DocumentSync(uri, languageId, doc);
		this.sync = sync;
		this.send("textDocument/didOpen", sync.opened(doc));
	}

	uri(): string | null { return this.sync === null ? null : (this.sync as DocumentSync).uri; }

	changed(doc: Document): void {
		if (this.sync === null) { return; }
		const params = (this.sync as DocumentSync).changed(doc, this.state == State.Ready ? this.syncKind : SyncKind.Full);
		if (params !== null) { this.send("textDocument/didChange", params as string); }
	}

	saved(doc: Document): void {
		if (this.sync === null) { return; }
		this.changed(doc);
		this.send("textDocument/didSave", (this.sync as DocumentSync).saved(doc, this.saveText));
	}

	shutdown(done: () => void): void {
		if (this.state != State.Ready) {
			this.state = State.Stopped;
			done();
			return;
		}
		if (this.sync !== null) { this.client.notify("textDocument/didClose", (this.sync as DocumentSync).closed()); }
		const _id = this.client.request("shutdown", "null", (r: Reply): void => {
			this.client.notify("exit", "null");
			this.state = State.Stopped;
			done();
		});
	}

	ended(): void { this.state = State.Stopped; }

	offsetNow(doc: Document, p: Position, bias: Bias): int32 {
		if (this.sync === null) { return 0; }
		return (this.sync as DocumentSync).offsetNow(doc, p, bias);
	}

	// Null when the diagnostics name another document, or a version whose text is no longer kept.
	diagnosticsOf(doc: Document, params: JsonValue): Diagnostic[] | null {
		if (this.sync === null || params.getDynamicField("uri").asString() != (this.sync as DocumentSync).uri) { return null; }
		const sync = this.sync as DocumentSync;
		const v = params.getDynamicField("version");
		const version: int32 | null = isKind(v, JsonKind.Null) ? null : v.asInt32();
		if (version !== null && !sync.keeps(version as int32)) { return null; }
		const list = params.getDynamicField("diagnostics");
		const out: Diagnostic[] = [];
		for (let i = 0; i < list.length(); i++) {
			const d = list.at(i);
			const range = rangeOf(d.getDynamicField("range"));
			const from = sync.offsetAt(doc, version, range.start, Bias.Right);
			const to = sync.offsetAt(doc, version, range.end, Bias.Left);
			if (from === null || to === null) { return null; }
			out.push({
				from: from as int32,
				to: Math.max(from as int32, to as int32),
				severity: severityOf(d.getDynamicField("severity").asInt32(1)),
				message: d.getDynamicField("message").asString(),
				source: d.getDynamicField("source").asString(),
				unnecessary: tagged(d.getDynamicField("tags"), UNNECESSARY),
			});
		}
		return out;
	}

	private at(doc: Document, offset: int32): string {
		const params: PositionParams = {
			textDocument: { uri: (this.sync as DocumentSync).uri },
			position: doc.positionOf(offset),
		};
		return JSON.stringify<PositionParams>(params);
	}

	private request(doc: Document, method: string, params: string, done: (result: JsonValue, version: int32) => void, refused: (message: string) => void): int32 {
		if (this.state != State.Ready || this.sync === null) { return -1; }
		this.changed(doc);
		const sync = this.sync as DocumentSync;
		const version = sync.lspVersion();
		return this.client.request(method, params, (r: Reply): void => {
			if (r.failed()) { refused(r.message); }
			else { done(r.result, version); }
		});
	}

	private ask(doc: Document, method: string, offset: int32, done: (result: JsonValue, version: int32) => void): int32 {
		if (this.state != State.Ready || this.sync === null) { return -1; }
		return this.request(doc, method, this.at(doc, offset), done, (message: string): void => {});
	}

	private span(doc: Document, version: int32, range: Range, first: Bias = Bias.Right, last: Bias = Bias.Left): Span | null {
		if (this.sync === null) { return null; }
		const sync = this.sync as DocumentSync;
		const from = sync.offsetAt(doc, version, range.start, first);
		const to = sync.offsetAt(doc, version, range.end, last);
		if (from === null || to === null) { return null; }
		return { from: from as int32, to: Math.max(from as int32, to as int32) };
	}

	private edits(doc: Document, version: int32, list: JsonValue): Edit[] | null {
		const out: Edit[] = [];
		for (let i = 0; i < list.length(); i++) {
			const e = list.at(i);
			const s = this.span(doc, version, rangeOf(e.getDynamicField("range")), Bias.Left, Bias.Right);
			if (s === null) { return null; }
			out.push({ from: (s as Span).from, to: (s as Span).to, text: e.getDynamicField("newText").asString().split("\r\n").join("\n") });
		}
		return refined(doc, out);
	}

	// One completion item, its offsets as the document is now; null when a range of it names
	// text the server saw that is no longer kept. `here` is where completion was asked, now.
	private completionOf(doc: Document, version: int32, item: JsonValue, defaults: JsonValue, here: int32): Completion | null {
		const label = item.getDynamicField("label").asString();
		const edit = item.getDynamicField("textEdit");
		const defaultRange = defaults.getDynamicField("editRange");
		const inserted = item.getDynamicField("insertText");
		const textEditText = item.getDynamicField("textEditText");
		let newText = present(inserted) ? inserted.asString() : label;
		if (present(edit)) { newText = edit.getDynamicField("newText").asString(); }
		else if (present(defaultRange) && present(textEditText)) { newText = textEditText.asString(); }
		const ranges = present(edit) ? edit : defaultRange;
		let replaceFrom: int32 = 0;
		let replaceTo: int32 = 0;
		let insertTo: int32 | null = null;
		const replace = ranges.getDynamicField("replace");
		const plain = present(edit) ? edit.getDynamicField("range") : defaultRange;
		if (present(replace)) {
			const r = this.span(doc, version, rangeOf(replace), Bias.Left, Bias.Right);
			const i = this.span(doc, version, rangeOf(ranges.getDynamicField("insert")), Bias.Left, Bias.Right);
			if (r === null || i === null) { return null; }
			replaceFrom = (r as Span).from;
			replaceTo = (r as Span).to;
			insertTo = (i as Span).to;
		} else if (present(plain)) {
			const r = this.span(doc, version, rangeOf(plain), Bias.Left, Bias.Right);
			if (r === null) { return null; }
			replaceFrom = (r as Span).from;
			replaceTo = (r as Span).to;
		} else {
			const [from, to] = wordAround(doc, here);
			replaceFrom = from;
			replaceTo = to;
			insertTo = here;
		}
		const format = item.getDynamicField("insertTextFormat").asInt32(defaults.getDynamicField("insertTextFormat").asInt32(1));
		if (format == SNIPPET) { newText = snippetText(newText); }
		const extra = this.edits(doc, version, item.getDynamicField("additionalTextEdits"));
		if (extra === null) { return null; }
		const filterText = item.getDynamicField("filterText");
		const sortText = item.getDynamicField("sortText");
		const defaultData = defaults.getDynamicField("data");
		const raw = stringify(item);
		const now = doc.version();
		return {
			label,
			detail: item.getDynamicField("detail").asString(),
			documentation: documentationOf(item.getDynamicField("documentation")),
			filterText: present(filterText) ? filterText.asString() : label,
			sortText: present(sortText) ? sortText.asString() : null,
			kind: item.getDynamicField("kind").asInt32(0),
			deprecated: item.getDynamicField("deprecated").asBoolean(false) || tagged(item.getDynamicField("tags"), DEPRECATED),
			newText,
			replaceFrom,
			replaceTo,
			insertTo,
			at: now,
			extra: extra as Edit[],
			extraAt: now,
			resolved: false,
			raw: present(defaultData) && !present(item.getDynamicField("data")) ? withField(raw, "data", stringify(defaultData)) : raw,
		};
	}

	// Asks for completions at `offset`. `trigger` is the trigger character typed, or null when
	// the person asked or typed a word character. The list given to `done` is incomplete when
	// the server said so, or when an item named text no longer kept.
	completion(doc: Document, offset: int32, trigger: string | null, done: (items: Completion[], incomplete: boolean) => void): int32 {
		if (!this.provides("completionProvider")) { return -1; }
		const asked = doc.version();
		const context = trigger === null ? `{"triggerKind":${INVOKED}}`
			: `{"triggerKind":${TRIGGER_CHARACTER},"triggerCharacter":${quoted(trigger as string)}}`;
		const resolvable = this.capabilities.getDynamicField("completionProvider").getDynamicField("resolveProvider").asBoolean(false);
		const params = withField(this.at(doc, offset), "context", context);
		return this.request(doc, "textDocument/completion", params, (result: JsonValue, version: int32): void => {
			const here = doc.offsetSince(asked, offset, Bias.Right);
			if (here === null) {
				done([], false);
				return;
			}
			const listed = isKind(result, JsonKind.Array);
			const list = listed ? result : result.getDynamicField("items");
			let incomplete = !listed && result.getDynamicField("isIncomplete").asBoolean(false);
			const defaults = listed ? jsonNull() : result.getDynamicField("itemDefaults");
			const items: Completion[] = [];
			for (let i = 0; i < list.length(); i++) {
				const c = this.completionOf(doc, version, list.at(i), defaults, here as int32);
				if (c === null) { incomplete = true; }
				else { items.push({ ...(c as Completion), resolved: !resolvable }); }
			}
			done(items, incomplete);
		}, (message: string): void => { done([], false); });
	}

	// Fills in what the server left out of a completion until it was chosen or shown. `done`
	// gets the item marked resolved even when the server fails to answer, so it is asked once.
	resolve(doc: Document, item: Completion, done: (resolved: Completion) => void): int32 {
		const settled: Completion = { ...item, resolved: true };
		const id = this.request(doc, "completionItem/resolve", item.raw, (result: JsonValue, version: int32): void => {
			const detail = result.getDynamicField("detail");
			const documentation = result.getDynamicField("documentation");
			const added = result.getDynamicField("additionalTextEdits");
			const extra = present(added) ? this.edits(doc, version, added) : null;
			done({
				...settled,
				detail: present(detail) ? detail.asString() : item.detail,
				documentation: present(documentation) ? documentationOf(documentation) : item.documentation,
				extra: extra === null ? item.extra : extra as Edit[],
				extraAt: extra === null ? item.extraAt : doc.version(),
			});
		}, (message: string): void => { done(settled); });
		if (id < 0) { done(settled); }
		return id;
	}

	// The signatures of the call around the offset, with the one shown before sent back on a
	// retrigger so the server can keep it; `done` gets null when there are none.
	signatureHelp(doc: Document, q: SignatureAsk, done: (help: SignatureHelp | null) => void): int32 {
		if (!this.provides("signatureHelpProvider")) { return -1; }
		let context = `{"triggerKind":${q.trigger as int32},"isRetrigger":${q.shown !== null ? "true" : "false"}`;
		if (q.character !== null) { context += `,"triggerCharacter":${quoted(q.character as string)}`; }
		if (q.shown !== null) {
			const shown = q.shown as SignatureHelp;
			context += `,"activeSignatureHelp":{"signatures":${shown.raw},"activeSignature":${shown.active}}`;
		}
		const params = withField(this.at(doc, q.offset), "context", context + "}");
		return this.request(doc, "textDocument/signatureHelp", params, (result: JsonValue, version: int32): void => {
			const list = result.getDynamicField("signatures");
			if (!present(result) || list.length() == 0) {
				done(null);
				return;
			}
			const shared = result.getDynamicField("activeParameter");
			const signatures: Signature[] = [];
			for (let i = 0; i < list.length(); i++) { signatures.push(signatureOf(list.at(i), shared)); }
			done({ signatures, active: result.getDynamicField("activeSignature").asInt32(0), raw: stringify(list) });
		}, (message: string): void => { done(null); });
	}

	cancel(id: int32): void { if (id > 0) { this.client.cancel(id); } }

	// The places the symbol at the offset is read or written in this document; `done` gets null
	// when the server fails or names text no longer kept.
	documentHighlight(doc: Document, offset: int32, done: (found: Occurrence[] | null) => void): int32 {
		if (!this.provides("documentHighlightProvider")) { return -1; }
		return this.request(doc, "textDocument/documentHighlight", this.at(doc, offset), (result: JsonValue, version: int32): void => {
			const found: Occurrence[] = [];
			for (let i = 0; i < result.length(); i++) {
				const h = result.at(i);
				const s = this.span(doc, version, rangeOf(h.getDynamicField("range")));
				if (s === null) {
					done(null);
					return;
				}
				found.push({ from: (s as Span).from, to: (s as Span).to, write: h.getDynamicField("kind").asInt32(1) == WRITE_HIGHLIGHT });
			}
			done(found);
		}, (message: string): void => { done(null); });
	}

	// The edits that format the document, or the range of it, offsets as the document is when
	// they arrive; `done` gets the server's message instead when it refuses.
	format(doc: Document, range: Span | null, done: (edits: Edit[] | null, error: string | null) => void): int32 {
		const whole = range === null;
		if (!this.provides(whole ? "documentFormattingProvider" : "documentRangeFormattingProvider")) { return -1; }
		let params = `{"textDocument":{"uri":${quoted((this.sync as DocumentSync).uri)}},"options":${FORMATTING_OPTIONS}`;
		if (range !== null) {
			const r: Range = { start: doc.positionOf((range as Span).from), end: doc.positionOf((range as Span).to) };
			params += `,"range":${JSON.stringify<Range>(r)}`;
		}
		const method = whole ? "textDocument/formatting" : "textDocument/rangeFormatting";
		return this.request(doc, method, params + "}", (result: JsonValue, version: int32): void => {
			const edits: Edit[] | null = present(result) ? this.edits(doc, version, result) : [];
			if (edits === null) { done(null, "the answer names text no longer kept"); }
			else { done(edits as Edit[], null); }
		}, (message: string): void => { done(null, message); });
	}

	prepares(): boolean {
		return this.capabilities.getDynamicField("renameProvider").getDynamicField("prepareProvider").asBoolean(false);
	}

	prepareRename(doc: Document, offset: int32, done: (range: Span | null, error: string | null) => void): int32 {
		if (!this.prepares()) { return -1; }
		const asked = doc.version();
		return this.request(doc, "textDocument/prepareRename", this.at(doc, offset), (result: JsonValue, version: int32): void => {
			if (!present(result)) {
				done(null, null);
				return;
			}
			if (result.getDynamicField("defaultBehavior").asBoolean(false)) {
				const here = doc.offsetSince(asked, offset, Bias.Right);
				const word: [int32, int32] = here === null ? [0, 0] : wordAround(doc, here as int32);
				done(word[0] == word[1] ? null : { from: word[0], to: word[1] }, null);
				return;
			}
			const range = result.getDynamicField("range");
			const s = this.span(doc, version, rangeOf(present(range) ? range : result));
			if (s === null) { done(null, "the answer names text no longer kept"); }
			else { done(s, null); }
		}, (message: string): void => { done(null, message); });
	}

	rename(doc: Document, offset: int32, name: string, done: (edits: Edit[] | null, others: int32, error: string | null) => void): int32 {
		if (!this.provides("renameProvider")) { return -1; }
		const params = withField(this.at(doc, offset), "newName", quoted(name));
		return this.request(doc, "textDocument/rename", params, (result: JsonValue, version: int32): void => {
			if (present(result.getDynamicField("documentChanges"))) {
				done(null, 0, "the answer edits through documentChanges, which medic does not ask for");
				return;
			}
			const uri = (this.sync as DocumentSync).uri;
			const changes = result.getDynamicField("changes");
			let mine: JsonValue = jsonNull();
			let others = 0;
			const keys: string[] = match (changes.kind) {
				JsonKind.Object => changes.keys,
				_ => [],
			};
			for (const key of keys) {
				if (key == uri) { mine = changes.getDynamicField(key); }
				else if (changes.getDynamicField(key).length() > 0) { others += 1; }
			}
			const edits = this.edits(doc, version, mine);
			if (edits === null) { done(null, 0, "the answer names text no longer kept"); }
			else { done(edits as Edit[], others, null); }
		}, (message: string): void => { done(null, 0, message); });
	}

	hover(doc: Document, offset: int32, done: (text: string, over: Span | null) => void): int32 {
		if (!this.provides("hoverProvider")) { return -1; }
		return this.ask(doc, "textDocument/hover", offset, (result: JsonValue, version: int32): void => {
			if (result.kind == JsonKind.Null) {
				done("", null);
				return;
			}
			const range = result.getDynamicField("range");
			const text = hoverText(result.getDynamicField("contents"));
			done(text, range.kind == JsonKind.Null ? null : this.span(doc, version, rangeOf(range)));
		});
	}

	definition(doc: Document, offset: int32, done: (found: Target[]) => void): int32 {
		if (!this.provides("definitionProvider")) { return -1; }
		return this.ask(doc, "textDocument/definition", offset, (result: JsonValue, version: int32): void => {
			const found: Target[] = [];
			if (result.kind != JsonKind.Null) {
				for (const l of locationsOf(result)) {
					found.push({ uri: l.uri, range: l.range, here: l.uri == this.uri() ? this.span(doc, version, l.range) : null });
				}
			}
			done(found);
		});
	}
}

when (testBuild) {
	import { framed } from "./rpc";
	import { SignatureTrigger } from "../model/signatures";

	struct Wire {
		sent: string[];
	}

	function started(): [Server, Wire] {
		const wire: Wire = { sent: [] };
		const server = new Server((bytes: string): void => { wire.sent.push(bytes); }, (m: string): void => {});
		return [server, wire];
	}

	function reply(id: int32, result: string): string {
		return framed(`{"jsonrpc":"2.0","id":${id},"result":${result}}`);
	}

	test "notifications wait for initialize, then follow initialized in order" {
		const [server, wire] = started();
		const d = new Document("abc");
		let failure: string | null = "pending";
		server.initialize("file:///w", 7, (e: string | null): void => { failure = e; });
		server.open(d, "file:///w/a.ms", "metascript");
		const _e = d.splice({ from: 3, to: 3, text: "d" });
		server.changed(d);
		assert wire.sent.length == 1 && wire.sent[0].includes("\"method\":\"initialize\"");
		server.receive(reply(1, "{\"capabilities\":{\"textDocumentSync\":{\"openClose\":true,\"change\":2,\"save\":{\"includeText\":true}},\"hoverProvider\":true}}"));
		assert failure === null && server.ready();
		assert wire.sent.length == 4;
		assert wire.sent[1].includes("\"method\":\"initialized\"");
		assert wire.sent[2].includes("textDocument/didOpen") && wire.sent[2].includes("\"text\":\"abc\"");
		assert wire.sent[3].includes("textDocument/didChange") && wire.sent[3].includes("\"text\":\"abcd\"");
		const _f = d.splice({ from: 0, to: 1, text: "" });
		server.changed(d);
		assert wire.sent[4].includes("\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}}");
		server.saved(d);
		assert wire.sent[5].includes("textDocument/didSave") && wire.sent[5].includes("\"text\":\"bcd\"");
		assert server.provides("hoverProvider") && !server.provides("definitionProvider");
	}

	test "hover text joins marked strings and keeps a code block's language" {
		const parsed = JSON.parseValue("[\"one\",{\"language\":\"ms\",\"value\":\"let x\"}]");
		assert parsed.ok;
		if (parsed.ok) { assert hoverText(parsed.value) == "one\n\n```ms\nlet x\n```"; }
		const markup = JSON.parseValue("{\"kind\":\"markdown\",\"value\":\"**x** \"}");
		if (markup.ok) { assert hoverText(markup.value.getDynamicField("value")) == "**x**"; }
	}

	test "locations come from a location, a list, or location links" {
		const one = JSON.parseValue("{\"uri\":\"file:///a\",\"range\":{\"start\":{\"line\":1,\"character\":2},\"end\":{\"line\":1,\"character\":4}}}");
		if (one.ok) {
			const found = locationsOf(one.value);
			assert found.length == 1 && found[0].uri == "file:///a" && found[0].range.start.character == 2;
		}
		const links = JSON.parseValue("[{\"targetUri\":\"file:///b\",\"targetRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":9,\"character\":0}},\"targetSelectionRange\":{\"start\":{\"line\":3,\"character\":1},\"end\":{\"line\":3,\"character\":5}}}]");
		if (links.ok) {
			const found = locationsOf(links.value);
			assert found.length == 1 && found[0].uri == "file:///b" && found[0].range.start.line == 3;
		}
	}

	test "diagnostics map from the text the server saw onto the text now" {
		const [server, wire] = started();
		const d = new Document("ab\ncd\n");
		server.initialize(null, 1, (e: string | null): void => {});
		server.receive(reply(1, "{\"capabilities\":{\"textDocumentSync\":2}}"));
		server.open(d, "file:///a.ms", "metascript");
		const _e = d.splice({ from: 0, to: 0, text: "xx\n" });
		const stale = JSON.parseValue("{\"uri\":\"file:///a.ms\",\"version\":7,\"diagnostics\":[]}");
		assert stale.ok;
		if (stale.ok) { assert server.diagnosticsOf(d, stale.value) === null; }
		const params = JSON.parseValue("{\"uri\":\"file:///a.ms\",\"diagnostics\":[{\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":2}},\"severity\":2,\"message\":\"m\",\"source\":\"s\",\"tags\":[1]}]}");
		assert params.ok;
		if (params.ok) {
			const found = server.diagnosticsOf(d, params.value);
			assert found !== null;
			if (found !== null) {
				assert found.length == 1;
				assert found[0].from == 6 && found[0].to == 8 && found[0].severity == Severity.Warning;
				assert found[0].unnecessary;
			}
			const other = JSON.parseValue("{\"uri\":\"file:///other\"}");
			if (other.ok) { assert server.diagnosticsOf(d, other.value) === null; }
		}
	}

	function completing(text: string): [Server, Wire, Document] {
		const [server, wire] = started();
		const d = new Document(text);
		server.initialize(null, 1, (e: string | null): void => {});
		server.receive(reply(1, "{\"capabilities\":{\"textDocumentSync\":2,\"completionProvider\":{\"triggerCharacters\":[\".\"],\"resolveProvider\":true},"
			+ "\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]},\"documentFormattingProvider\":true,\"documentHighlightProvider\":true,"
			+ "\"renameProvider\":{\"prepareProvider\":true}}}"));
		server.open(d, "file:///a.ms", "metascript");
		return [server, wire, d];
	}

	test "a completion with no edit replaces the word around where it was asked, as the text is now" {
		const [server, wire, d] = completing("con;");
		let got: Completion[] = [];
		let more = true;
		const id = server.completion(d, 3, null, (items: Completion[], incomplete: boolean): void => {
			got = items;
			more = incomplete;
		});
		assert wire.sent[wire.sent.length - 1].includes("\"context\":{\"triggerKind\":1}}");
		const _e = d.splice({ from: 3, to: 3, text: "s" });
		server.receive(reply(id, "[{\"label\":\"console\",\"kind\":6,\"insertText\":\"console\",\"sortText\":\"11\",\"tags\":[1]}]"));
		assert got.length == 1 && !more;
		const c = got[0];
		assert c.newText == "console" && c.replaceFrom == 0 && c.replaceTo == 4 && c.insertTo == 4;
		assert c.at == d.version() && c.sortText == "11" && c.kind == 6 && c.deprecated && !c.resolved;
		const _t = server.completion(d, 4, ".", (items: Completion[], incomplete: boolean): void => {});
		assert wire.sent[wire.sent.length - 1].includes("\"context\":{\"triggerKind\":2,\"triggerCharacter\":\".\"}}");
	}

	test "a completion list's defaults give the ranges, the text and the data sent back to resolve" {
		const [server, wire, d] = completing("x.lo\n");
		let got: Completion[] = [];
		let more = false;
		const id = server.completion(d, 4, null, (items: Completion[], incomplete: boolean): void => {
			got = items;
			more = incomplete;
		});
		server.receive(reply(id, "{\"isIncomplete\":true,\"itemDefaults\":{"
			+ "\"editRange\":{\"insert\":{\"start\":{\"line\":0,\"character\":2},\"end\":{\"line\":0,\"character\":4}},"
			+ "\"replace\":{\"start\":{\"line\":0,\"character\":2},\"end\":{\"line\":0,\"character\":4}}},"
			+ "\"insertTextFormat\":2,\"data\":{\"n\":1}},\"items\":["
			+ "{\"label\":\"log\",\"textEditText\":\"log(${1:x})$0\"},"
			+ "{\"label\":\"b\",\"textEdit\":{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"newText\":\"b\"},"
			+ "\"additionalTextEdits\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"newText\":\"use\\n\"}],"
			+ "\"insertTextFormat\":1,\"data\":{\"own\":2}}]}"));
		assert got.length == 2 && more;
		assert got[0].newText == "log(x)" && got[0].replaceFrom == 2 && got[0].replaceTo == 4 && got[0].insertTo == 4;
		assert got[0].raw.includes("\"data\":{\"n\":1}");
		assert got[1].newText == "b" && got[1].replaceFrom == 0 && got[1].replaceTo == 1 && got[1].insertTo === null;
		assert got[1].extra.length == 1 && got[1].extra[0].text == "use\n" && got[1].raw.includes("\"own\":2") && !got[1].raw.includes("\"n\":1");
		let resolved: Completion | null = null;
		const rid = server.resolve(d, got[0], (c: Completion): void => { resolved = c; });
		assert wire.sent[wire.sent.length - 1].includes("completionItem/resolve") && wire.sent[wire.sent.length - 1].includes("\"n\":1");
		server.receive(reply(rid, "{\"label\":\"log\",\"documentation\":{\"kind\":\"plaintext\",\"value\":\"a*b\"},"
			+ "\"additionalTextEdits\":[{\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":0}},\"newText\":\"z\"}]}"));
		assert resolved !== null;
		if (resolved !== null) {
			const r = resolved as Completion;
			assert r.resolved && r.documentation == "a\\*b" && r.detail == "" && r.extra.length == 1 && r.extra[0].from == 5;
		}
	}

	test "a failed resolve still settles the item" {
		const [server, wire, d] = completing("a");
		let item: Completion | null = null;
		const id = server.completion(d, 1, null, (items: Completion[], incomplete: boolean): void => { item = items[0]; });
		server.receive(reply(id, "[{\"label\":\"ab\",\"detail\":\"d\"}]"));
		let settled = false;
		const rid = server.resolve(d, item as Completion, (c: Completion): void => { settled = c.resolved && c.detail == "d"; });
		server.receive(framed(`{"jsonrpc":"2.0","id":${rid},"error":{"code":-32603,"message":"no"}}`));
		assert settled;
	}

	test "signature help finds parameters by text or UTF-16 range and sends the shown help back on a retrigger" {
		const [server, wire, d] = completing("f(1, ");
		let got: SignatureHelp | null = null;
		const ask: SignatureAsk = { offset: 5, trigger: SignatureTrigger.Character, character: ",", shown: null };
		const id = server.signatureHelp(d, ask, (h: SignatureHelp | null): void => { got = h; });
		assert wire.sent[wire.sent.length - 1].includes("\"context\":{\"triggerKind\":2,\"isRetrigger\":false,\"triggerCharacter\":\",\"}}");
		server.receive(reply(id, "{\"activeSignature\":1,\"activeParameter\":1,\"signatures\":["
			+ "{\"label\":\"f(é: int32, b: string)\",\"parameters\":[{\"label\":[2,10]},{\"label\":\"b: string\",\"documentation\":\"the b\"}]},"
			+ "{\"label\":\"f(x)\",\"activeParameter\":0,\"documentation\":{\"kind\":\"markdown\",\"value\":\"**f**\"},\"parameters\":[{\"label\":\"y\"}]}]}"));
		assert got !== null;
		const h = got as SignatureHelp;
		assert h.active == 1 && h.signatures.length == 2;
		const first = h.signatures[0];
		assert first.active == 1 && first.parameters[0].from == 2 && first.parameters[0].to == 11;
		assert first.parameters[1].from == 13 && first.parameters[1].to == 22 && first.parameters[1].documentation == "the b";
		const second = h.signatures[1];
		assert second.active == 0 && second.documentation == "**f**" && second.parameters[0].from == -1;
		const _again = server.signatureHelp(d, { ...ask, trigger: SignatureTrigger.ContentChange, character: null, shown: { ...h, active: 0 } }, (x: SignatureHelp | null): void => {});
		const sent = wire.sent[wire.sent.length - 1];
		assert sent.includes("\"isRetrigger\":true,\"activeSignatureHelp\":{\"signatures\":[{\"label\":\"f(") && sent.includes("\"activeSignature\":0}}");
		let none = true;
		const nid = server.signatureHelp(d, ask, (x: SignatureHelp | null): void => { none = x === null; });
		server.receive(reply(nid, "null"));
		assert none;
	}

	test "formatting sends the indent options, a range only for a selection, and gives edits or the refusal" {
		const [server, wire, d] = completing("a  =1\n");
		let got: Edit[] = [];
		let error: string | null = null;
		const id = server.format(d, null, (edits: Edit[] | null, e: string | null): void => {
			if (edits !== null) { got = edits as Edit[]; }
			error = e;
		});
		const sent = wire.sent[wire.sent.length - 1];
		assert sent.includes("\"method\":\"textDocument/formatting\"") && sent.includes("\"tabSize\":4,\"insertSpaces\":false") && !sent.includes("\"range\"");
		const _e = d.splice({ from: 0, to: 0, text: "x" });
		server.receive(reply(id, "[{\"range\":{\"start\":{\"line\":0,\"character\":1},\"end\":{\"line\":0,\"character\":3}},\"newText\":\" \"}]"));
		assert got.length == 1 && got[0].from == 2 && got[0].to == 4 && error === null;
		const part: Span = { from: 0, to: 2 };
		assert server.format(d, part, (edits: Edit[] | null, e: string | null): void => {}) == -1;
		const fid = server.format(d, null, (edits: Edit[] | null, e: string | null): void => { error = e; });
		server.receive(framed(`{"jsonrpc":"2.0","id":${fid},"error":{"code":-32603,"message":"cannot parse"}}`));
		assert error !== null && (error as string) == "cannot parse";
	}

	test "document highlights come as read or written places, none for a null answer" {
		const [server, wire, d] = completing("ab = ab;\n");
		let found: Occurrence[] | null = null;
		const id = server.documentHighlight(d, 1, (o: Occurrence[] | null): void => { found = o; });
		assert wire.sent[wire.sent.length - 1].includes("\"method\":\"textDocument/documentHighlight\"");
		server.receive(reply(id, "[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":2}},\"kind\":3},"
			+ "{\"range\":{\"start\":{\"line\":0,\"character\":5},\"end\":{\"line\":0,\"character\":7}}}]"));
		assert found !== null;
		const f = found as Occurrence[];
		assert f.length == 2 && f[0].write && f[0].to == 2 && !f[1].write && f[1].from == 5;
		const nid = server.documentHighlight(d, 1, (o: Occurrence[] | null): void => { found = o; });
		server.receive(reply(nid, "null"));
		assert found !== null && (found as Occurrence[]).length == 0;
	}

	test "a prepared rename gives the range, the word for the default behaviour, or nothing" {
		const [server, wire, d] = completing("let abc = 1;\n");
		let got: Span | null = null;
		let error: string | null = null;
		const keep = (range: Span | null, e: string | null): void => {
			got = range;
			error = e;
		};
		assert server.prepares();
		const id = server.prepareRename(d, 5, keep);
		assert wire.sent[wire.sent.length - 1].includes("\"method\":\"textDocument/prepareRename\"");
		server.receive(reply(id, "{\"range\":{\"start\":{\"line\":0,\"character\":4},\"end\":{\"line\":0,\"character\":7}},\"placeholder\":\"abc\"}"));
		assert got !== null && (got as Span).from == 4 && (got as Span).to == 7;
		const did = server.prepareRename(d, 5, keep);
		server.receive(reply(did, "{\"defaultBehavior\":true}"));
		assert got !== null && (got as Span).from == 4 && (got as Span).to == 7;
		const nid = server.prepareRename(d, 3, keep);
		server.receive(reply(nid, "null"));
		assert got === null && error === null;
	}

	test "a rename gives this document's edits and counts the other documents it edits" {
		const [server, wire, d] = completing("ab = ab;\n");
		let got: Edit[] = [];
		let others = -1;
		let error: string | null = null;
		const keep = (edits: Edit[] | null, n: int32, e: string | null): void => {
			if (edits !== null) { got = edits as Edit[]; }
			others = n;
			error = e;
		};
		const id = server.rename(d, 1, "cd", keep);
		const sent = wire.sent[wire.sent.length - 1];
		assert sent.includes("\"method\":\"textDocument/rename\"") && sent.includes("\"newName\":\"cd\"");
		const edit = (from: int32, to: int32): string =>
			`{"range":{"start":{"line":0,"character":${from}},"end":{"line":0,"character":${to}}},"newText":"cd"}`;
		server.receive(reply(id, `{"changes":{"file:///b.ms":[${edit(0, 2)}],"file:///a.ms":[${edit(0, 2)},${edit(5, 7)}],"file:///c.ms":[]}}`));
		assert got.length == 2 && got[1].from == 5 && got[1].text == "cd" && others == 1 && error === null;
		const did = server.rename(d, 1, "cd", keep);
		server.receive(reply(did, "{\"documentChanges\":[]}"));
		assert error !== null;
	}
}
