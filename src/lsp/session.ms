import { Document } from "../model/document";
import { Diagnostic, Diagnostics } from "../model/diagnostics";
import { Completion } from "../model/completion";
import { Server, Span, Target } from "./server";

export interface Link {
	send: (bytes: string) => boolean;
	take: () => string;
	ended: () => boolean;
	stop: () => void;
	listen: (ready: () => void) => void;
}

export class Session {
	readonly name: string;
	readonly diagnostics: Diagnostics = new Diagnostics();
	private server: Server;
	private link: Link;
	private doc: Document;
	private note: string = "";
	private watchers: Array<() => void> = [];

	constructor(link: Link, name: string, doc: Document, uri: string, languageId: string, rootUri: string | null, processId: int32 | null) {
		this.link = link;
		this.name = name;
		this.doc = doc;
		this.server = new Server(
			(bytes: string): void => {
				if (!link.send(bytes)) { this.told(`${name} stopped taking messages`); }
			},
			(message: string): void => { this.told(`${name}: ${message}`); },
		);
		this.server.on("textDocument/publishDiagnostics", (params: JsonValue): void => {
			const found = this.server.diagnosticsOf(doc, params);
			if (found === null) { return; }
			this.diagnostics.replace(doc, found as Diagnostic[]);
			this.changed();
		});
		this.server.on("window/showMessage", (params: JsonValue): void => {
			this.told(`${name}: ${params.getDynamicField("message").asString()}`);
		});
		link.listen((): void => { this.pump(); });
		this.server.initialize(rootUri, processId, (error: string | null): void => {
			if (error !== null) { this.note = `${name}: ${error as string}`; }
			this.changed();
		});
		this.server.open(doc, uri, languageId);
	}

	private told(message: string): void {
		this.note = message;
		this.changed();
	}

	private changed(): void {
		for (const w of this.watchers) { w(); }
	}

	watch(handler: () => void): void { this.watchers.push(handler); }

	pump(): void {
		const bytes = this.link.take();
		if (bytes.byteLength > 0) { this.server.receive(bytes); }
		if (this.link.ended() && !this.server.stopped()) {
			this.server.ended();
			this.diagnostics.replace(this.doc, []);
			this.told(`${this.name} exited`);
		}
	}

	status(): string {
		if (this.note.byteLength > 0) { return this.note; }
		if (this.server.stopped()) { return `${this.name} stopped`; }
		return this.server.ready() ? "" : `${this.name} starting`;
	}

	ready(): boolean { return this.server.ready(); }

	edited(): void { this.server.changed(this.doc); }

	saved(): void { this.server.saved(this.doc); }

	hover(offset: int32, done: (text: string, over: Span | null) => void): int32 {
		return this.server.hover(this.doc, offset, done);
	}

	definition(offset: int32, done: (found: Target[]) => void): int32 {
		return this.server.definition(this.doc, offset, done);
	}

	completion(offset: int32, trigger: string | null, done: (items: Completion[], incomplete: boolean) => void): int32 {
		return this.server.completion(this.doc, offset, trigger, done);
	}

	resolveCompletion(item: Completion, done: (resolved: Completion) => void): int32 {
		return this.server.resolve(this.doc, item, done);
	}

	completionTriggers(): string[] { return this.server.triggers("completionProvider", "triggerCharacters"); }

	cancel(id: int32): void { this.server.cancel(id); }

	stop(): void {
		this.server.shutdown((): void => { this.link.stop(); });
		this.pump();
	}
}

when (testBuild) {
	import { framed } from "./rpc";

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
	}

	test "a session opens the document, keeps the diagnostics it is sent, and notices the server end" {
		const pipe = new Pipe();
		const d = new Document("let x = 1;\n");
		const session = new Session(pipe.link(), "msc lsp", d, "file:///a.ms", "metascript", null, null);
		let changes = 0;
		session.watch((): void => { changes += 1; });
		assert session.status() == "msc lsp starting";
		pipe.deliver("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"textDocumentSync\":2,\"hoverProvider\":true}}}");
		assert session.ready() && session.status() == "";
		assert pipe.sent.length == 3 && pipe.sent[2].includes("didOpen");
		pipe.deliver("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///a.ms\",\"version\":0,\"diagnostics\":[{\"range\":{\"start\":{\"line\":0,\"character\":4},\"end\":{\"line\":0,\"character\":5}},\"severity\":1,\"message\":\"unused\"}]}}");
		assert session.diagnostics.count() == 1 && changes == 2;
		let shown = "";
		let over: Span | null = null;
		const id = session.hover(4, (text: string, s: Span | null): void => {
			shown = text;
			over = s;
		});
		assert id == 2;
		const _e = d.splice({ from: 0, to: 0, text: "  " });
		pipe.deliver("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"contents\":\"x: int32\",\"range\":{\"start\":{\"line\":0,\"character\":4},\"end\":{\"line\":0,\"character\":5}}}}");
		assert shown == "x: int32";
		assert over !== null && (over as Span).from == 6 && (over as Span).to == 7;
		pipe.over = true;
		pipe.ready();
		assert session.status() == "msc lsp exited" && session.diagnostics.count() == 0;
	}
}
