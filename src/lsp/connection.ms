import { Document } from "../model/document";
import { Away, Server } from "./server";
import { Link, Session } from "./session";
import { sameFile } from "./uri";

export class Connection {
	readonly name: string;
	private link: Link;
	private server: Server;
	private sessions: Session[] = [];
	private note: string = "";
	private watchers: Array<() => void> = [];

	constructor(link: Link, name: string, rootUri: string | null, processId: int32 | null) {
		this.link = link;
		this.name = name;
		this.server = new Server(
			(bytes: string): void => {
				if (!link.send(bytes)) { this.told(`${name} stopped taking messages`); }
			},
			(message: string): void => { this.told(`${name}: ${message}`); },
		);
		this.server.on("textDocument/publishDiagnostics", (params: JsonValue): void => {
			const uri = params.getDynamicField("uri").asString();
			for (const s of this.sessions) {
				if (sameFile(uri, s.uri) && s.diagnosed(params)) {
					s.changed();
					this.notify();
				}
			}
		});
		this.server.on("window/showMessage", (params: JsonValue): void => {
			this.told(`${name}: ${params.getDynamicField("message").asString()}`);
		});
		link.listen((): void => { this.pump(); });
		this.server.initialize(rootUri, processId, (error: string | null): void => {
			if (error !== null) { this.note = `${name}: ${error as string}`; }
			this.changed();
		});
	}

	open(doc: Document, uri: string, languageId: string): Session {
		const s = new Session(this.server, this.name, doc, uri, languageId, (): string => this.status(), (gone: Session): void => {
			this.sessions = this.sessions.filter((x: Session): boolean => x !== gone);
		});
		this.sessions.push(s);
		return s;
	}

	private told(message: string): void {
		this.note = message;
		this.changed();
	}

	private notify(): void {
		for (const w of this.watchers) { w(); }
	}

	private changed(): void {
		this.notify();
		for (const s of this.sessions) { s.changed(); }
	}

	watch(handler: () => void): void { this.watchers.push(handler); }

	editsElsewhere(apply: (files: Away[]) => string | null): void { this.server.editsElsewhere(apply); }

	private pump(): void {
		const bytes = this.link.take();
		if (bytes.byteLength > 0) { this.server.receive(bytes); }
		if (this.link.ended() && !this.server.stopped()) {
			this.server.ended();
			for (const s of this.sessions) { s.ended(); }
			this.told(`${this.name} exited`);
		}
	}

	status(): string {
		if (this.note.byteLength > 0) { return this.note; }
		if (this.server.stopped()) { return `${this.name} stopped`; }
		return this.server.ready() ? "" : `${this.name} starting`;
	}

	ready(): boolean { return this.server.ready(); }

	stop(): void {
		this.server.shutdown((): void => { this.link.stop(); });
		this.pump();
	}
}

when (testBuild) {
	import { framed } from "./rpc";
	import { Edit } from "../model/document";
	import { Place } from "../model/references";
	import { Span, editsIn } from "./server";

	class Pipe {
		sent: string[] = [];
		inbox: string = "";
		over: boolean = false;
		ready: () => void = (): void => {};

		link(): Link {
			return {
				send: (bytes: string): boolean => {
					this.sent.push(bytes);
					return !this.over;
				},
				take: (): string => {
					const bytes = this.inbox;
					this.inbox = "";
					return bytes;
				},
				ended: (): boolean => this.over,
				stop: (): void => { this.over = true; },
				listen: (ready: () => void): void => { this.ready = ready; },
			};
		}

		deliver(body: string): void {
			this.inbox = this.inbox + framed(body);
			this.ready();
		}

		count(method: string): int32 {
			return this.sent.filter((s: string): boolean => s.includes(`"method":"${method}"`)).length as int32;
		}
	}

	const INITIALIZED = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"textDocumentSync\":2,\"hoverProvider\":true,\"renameProvider\":true,\"referencesProvider\":true}}}";

	function diagnose(uri: string, message: string): string {
		return `{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"${uri}","diagnostics":[`
			+ `{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"severity":1,"message":"${message}"}]}}`;
	}

	function at(line: int32, from: int32, to: int32): string {
		return `{"start":{"line":${line},"character":${from}},"end":{"line":${line},"character":${to}}}`;
	}

	test "a session opens the document, keeps the diagnostics it is sent, and notices the server end" {
		const pipe = new Pipe();
		const d = new Document("let x = 1;\n");
		const connection = new Connection(pipe.link(), "msc lsp", null, null);
		const session = connection.open(d, "file:///a.ms", "metascript");
		let changes = 0;
		session.watch((): void => { changes += 1; });
		assert session.status() == "msc lsp starting" && session.uri == "file:///a.ms";
		pipe.deliver(INITIALIZED);
		assert session.ready() && session.status() == "";
		assert pipe.sent.length == 3 && pipe.sent[2].includes("didOpen");
		pipe.deliver(diagnose("file:///a.ms", "unused"));
		assert session.diagnostics.count() == 1 && changes == 2;
		let shown = "";
		let over: Span | null = null;
		const id = session.hover(4, (text: string, s: Span | null): void => {
			shown = text;
			over = s;
		});
		assert id == 2;
		const _e = d.splice({ from: 0, to: 0, text: "  " });
		pipe.deliver("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"contents\":\"x: int32\",\"range\":" + at(0, 4, 5) + "}}");
		assert shown == "x: int32";
		assert over !== null && (over as Span).from == 6 && (over as Span).to == 7;
		pipe.over = true;
		pipe.ready();
		assert session.status() == "msc lsp exited" && connection.status() == "msc lsp exited" && session.diagnostics.count() == 0;
	}

	test "two documents on one connection share one initialize and each is opened once" {
		const pipe = new Pipe();
		const connection = new Connection(pipe.link(), "msc lsp", "file:///w", 7);
		const a = connection.open(new Document("a"), "file:///w/a.ms", "metascript");
		const b = connection.open(new Document("b"), "file:///w/b.ms", "metascript");
		let changes = 0;
		connection.watch((): void => { changes += 1; });
		pipe.deliver(INITIALIZED);
		assert connection.ready() && a.ready() && b.ready() && changes == 1;
		assert pipe.count("initialize") == 1 && pipe.count("initialized") == 1 && pipe.count("textDocument/didOpen") == 2;
		assert pipe.sent[2].includes("file:///w/a.ms") && pipe.sent[3].includes("file:///w/b.ms");
		connection.stop();
		assert pipe.count("textDocument/didClose") == 2 && pipe.count("shutdown") == 1;
	}

	test "diagnostics reach the session of their uri, and none once it is closed" {
		const pipe = new Pipe();
		const connection = new Connection(pipe.link(), "msc lsp", null, null);
		const a = connection.open(new Document("a\n"), "file:///a.ms", "metascript");
		const b = connection.open(new Document("b\n"), "file:///b.ms", "metascript");
		let seenA = 0;
		let seenB = 0;
		a.watch((): void => { seenA += 1; });
		b.watch((): void => { seenB += 1; });
		pipe.deliver(INITIALIZED);
		pipe.deliver(diagnose("file:///b.ms", "in b"));
		assert a.diagnostics.count() == 0 && b.diagnostics.count() == 1 && seenA == 1 && seenB == 2;
		pipe.deliver(diagnose("file:///c.ms", "nowhere"));
		assert a.diagnostics.count() == 0 && b.diagnostics.count() == 1;
		b.close();
		assert pipe.sent[pipe.sent.length - 1].includes("textDocument/didClose") && pipe.sent[pipe.sent.length - 1].includes("file:///b.ms");
		assert b.diagnostics.count() == 0 && !b.ready() && a.ready();
		pipe.deliver(diagnose("file:///b.ms", "late"));
		assert b.diagnostics.count() == 0 && seenB == 2;
		assert b.hover(0, (text: string, s: Span | null): void => {}) == -1;
		b.close();
		assert pipe.count("textDocument/didClose") == 1;
	}

	test "a workspace edit reaches every open document it names and hands over the files that are not open" {
		const pipe = new Pipe();
		const connection = new Connection(pipe.link(), "msc lsp", null, null);
		const da = new Document("ab = ab;\n");
		const db = new Document("x = ab;\n");
		const a = connection.open(da, "file:///a.ms", "metascript");
		const b = connection.open(db, "file:///b.ms", "metascript");
		const gotA: Edit[] = [];
		const gotB: Edit[] = [];
		const othersSeen: int32[] = [];
		a.applying((edits: Edit[], others: int32): string | null => {
			for (const e of edits) { gotA.push(e); }
			othersSeen.push(others);
			return null;
		});
		b.applying((edits: Edit[], others: int32): string | null => {
			for (const e of edits) { gotB.push(e); }
			othersSeen.push(others);
			return null;
		});
		const away: Away[] = [];
		connection.editsElsewhere((files: Away[]): string | null => {
			for (const f of files) { away.push(f); }
			return null;
		});
		pipe.deliver(INITIALIZED);
		const edit = (line: int32, from: int32, to: int32): string => `{"range":${at(line, from, to)},"newText":"cd"}`;
		const changes = `{"changes":{"file:///a.ms":[${edit(0, 0, 2)},${edit(0, 5, 7)}],"file:///b.ms":[${edit(0, 4, 6)}],"file:///c.ms":[${edit(1, 0, 2)}]}}`;
		pipe.deliver(`{"jsonrpc":"2.0","id":50,"method":"workspace/applyEdit","params":{"edit":${changes}}}`);
		assert gotA.length == 2 && gotA[1].from == 5 && gotB.length == 1 && gotB[0].from == 4;
		assert othersSeen.length == 2 && othersSeen[0] == 3 && othersSeen[1] == 3;
		assert away.length == 1 && away[0].uri == "file:///c.ms" && away[0].edits.length == 1 && away[0].edits[0].range.start.line == 1;
		assert editsIn(new Document("x\nab\n"), away[0])[0].from == 2;
		assert pipe.sent[pipe.sent.length - 1].includes("\"id\":50,\"result\":{\"applied\":true}");
		let mine: Edit[] = [];
		let counted: int32 = -1;
		const id = a.rename(1, "cd", (edits: Edit[] | null, others: int32, error: string | null): void => {
			if (edits !== null) { mine = edits as Edit[]; }
			counted = others;
		});
		pipe.deliver(`{"jsonrpc":"2.0","id":${id},"result":${changes}}`);
		assert mine.length == 2 && counted == 2 && gotA.length == 2 && gotB.length == 2;
		b.applying((edits: Edit[], others: int32): string | null => "no");
		const refusedId = a.rename(1, "cd", (edits: Edit[] | null, others: int32, error: string | null): void => {
			mine = edits === null ? [] : edits as Edit[];
			counted = error !== null && (error as string) == "no" ? 0 : -1;
		});
		pipe.deliver(`{"jsonrpc":"2.0","id":${refusedId},"result":${changes}}`);
		assert mine.length == 0 && counted == 0;
		connection.editsElsewhere((files: Away[]): string | null => "cannot read c.ms");
		const before = gotA.length;
		pipe.deliver(`{"jsonrpc":"2.0","id":52,"method":"workspace/applyEdit","params":{"edit":${changes}}}`);
		assert gotA.length == before && pipe.sent[pipe.sent.length - 1].includes("\"id\":52,\"result\":{\"applied\":false");
		pipe.deliver(`{"jsonrpc":"2.0","id":51,"method":"workspace/applyEdit","params":{"edit":{"changes":{"file:///c.ms":[${edit(0, 0, 1)}]}}}}`);
		assert pipe.sent[pipe.sent.length - 1].includes("\"id\":51,\"result\":{\"applied\":false");
	}

	test "references place their ranges in the asked document only, and name the others by line" {
		const pipe = new Pipe();
		const connection = new Connection(pipe.link(), "msc lsp", null, null);
		const a = connection.open(new Document("ab = 1;\n"), "file:///a.ms", "metascript");
		const db = new Document("x = ab;\n");
		const _b = connection.open(db, "file:///b.ms", "metascript");
		pipe.deliver(INITIALIZED);
		let found: Place[] | null = null;
		const id = a.references(0, (p: Place[] | null): void => { found = p; });
		const _e = db.splice({ from: 0, to: 0, text: "yy" });
		pipe.deliver(`{"jsonrpc":"2.0","id":${id},"result":[{"uri":"file:///a.ms","range":${at(0, 0, 2)}},`
			+ `{"uri":"file:///b.ms","range":${at(0, 4, 6)}},{"uri":"file:///c.ms","range":${at(0, 0, 2)}}]}`);
		const f = found as Place[];
		assert f.length == 3 && f[0].here !== null && f[1].here === null && f[2].here === null;
		assert f[1].uri == "file:///b.ms" && f[1].line == 0 && f[1].character == 4;
	}
}
