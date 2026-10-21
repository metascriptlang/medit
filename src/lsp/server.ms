import { Document, mapOffset, Bias } from "../model/document";
import { Diagnostic, Severity } from "../model/diagnostics";
import { Client, NotificationHandler, Reply, failed } from "./client";
import { DocumentSync, SyncKind } from "./sync";
import { Position, Range, offsetIn, positionOf } from "./position";
import { isKind } from "./json";

const CLIENT_CAPABILITIES = "{"
	+ "\"general\":{\"positionEncodings\":[\"utf-16\"]},"
	+ "\"textDocument\":{"
	+ "\"synchronization\":{\"didSave\":true},"
	+ "\"publishDiagnostics\":{\"versionSupport\":true,\"tagSupport\":{\"valueSet\":[1,2]}},"
	+ "\"hover\":{\"contentFormat\":[\"markdown\",\"plaintext\"]},"
	+ "\"definition\":{\"linkSupport\":true}"
	+ "},"
	+ "\"workspace\":{\"configuration\":true},"
	+ "\"window\":{\"workDoneProgress\":false,\"showMessage\":{}}"
	+ "}";

const FENCE = "```";

export enum State {
	Starting,
	Ready,
	Stopped,
}

export struct Location {
	uri: string;
	range: Range;
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

	private ask(doc: Document, method: string, params: string, done: (result: JsonValue) => void): int32 {
		if (this.state != State.Ready || this.sync === null) { return -1; }
		this.changed(doc);
		return this.client.request(method, params, (r: Reply): void => {
			if (!r.failed()) { done(r.result); }
		});
	}

	cancel(id: int32): void { if (id > 0) { this.client.cancel(id); } }

	hover(doc: Document, offset: int32, done: (text: string, range: Range | null) => void): int32 {
		if (!this.provides("hoverProvider")) { return -1; }
		return this.ask(doc, "textDocument/hover", this.sync === null ? "" : this.at(doc, offset), (result: JsonValue): void => {
			if (result.kind == JsonKind.Null) {
				done("", null);
				return;
			}
			const range = result.getDynamicField("range");
			done(hoverText(result.getDynamicField("contents")), range.kind == JsonKind.Null ? null : rangeOf(range));
		});
	}

	definition(doc: Document, offset: int32, done: (found: Location[]) => void): int32 {
		if (!this.provides("definitionProvider")) { return -1; }
		return this.ask(doc, "textDocument/definition", this.sync === null ? "" : this.at(doc, offset), (result: JsonValue): void => {
			done(result.kind == JsonKind.Null ? [] : locationsOf(result));
		});
	}
}

when (testBuild) {
	import { framed } from "./rpc";

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
}
