import { Document, Edit } from "../model/document";
import { Diagnostic, Diagnostics } from "../model/diagnostics";
import { Completion } from "../model/completion";
import { SignatureAsk, SignatureHelp } from "../model/signatures";
import { Occurrence } from "../model/occurrences";
import { Place } from "../model/references";
import { OutlineItem } from "../model/outline";
import { CodeAction } from "../model/actions";
import { Inlay } from "../model/inlays";
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
	private editing: (edits: Edit[], others: int32) => string | null = (edits: Edit[], others: int32): string | null => "nothing applies edits yet";

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
		this.server.applyEdits(doc, (edits: Edit[], others: int32): string | null => this.editing(edits, others));
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

	signatureHelp(q: SignatureAsk, done: (help: SignatureHelp | null) => void): int32 {
		return this.server.signatureHelp(this.doc, q, done);
	}

	signatureTriggers(): string[] {
		return this.server.triggers("signatureHelpProvider", "triggerCharacters")
			.concat(this.server.triggers("signatureHelpProvider", "retriggerCharacters"));
	}

	format(range: [int32, int32] | null, indent: string, done: (edits: Edit[] | null, error: string | null) => void): int32 {
		if (range === null) { return this.server.format(this.doc, null, indent, done); }
		const [from, to] = range as [int32, int32];
		const span: Span = { from, to };
		return this.server.format(this.doc, span, indent, done);
	}

	documentHighlight(offset: int32, done: (found: Occurrence[] | null) => void): int32 {
		return this.server.documentHighlight(this.doc, offset, done);
	}

	references(offset: int32, done: (found: Place[] | null) => void): int32 {
		return this.server.references(this.doc, offset, (found: Target[] | null): void => {
			if (found === null) {
				done(null);
				return;
			}
			done((found as Target[]).map((t: Target): Place => ({
				uri: t.uri,
				line: t.range.start.line,
				character: t.range.start.character,
				here: t.here === null ? null : [(t.here as Span).from, (t.here as Span).to],
			})));
		});
	}

	documentSymbols(done: (found: OutlineItem[] | null) => void): int32 {
		return this.server.documentSymbols(this.doc, done);
	}

	codeActions(from: int32, to: int32, done: (found: CodeAction[] | null) => void): int32 {
		return this.server.codeActions(this.doc, from, to, this.diagnostics.within(this.doc, from, to), done);
	}

	applyAction(action: CodeAction, done: (edits: Edit[] | null, others: int32, error: string | null) => void): int32 {
		return this.server.applyAction(this.doc, action, done);
	}

	inlayHints(from: int32, to: int32, done: (found: Inlay[] | null) => void): int32 {
		return this.server.inlayHints(this.doc, from, to, done);
	}

	// Who applies the edits the server asks for on its own, as after a code action's command.
	applying(handler: (edits: Edit[], others: int32) => string | null): void { this.editing = handler; }

	prepares(): boolean { return this.server.prepares(); }

	prepareRename(offset: int32, done: (range: [int32, int32] | null, error: string | null) => void): int32 {
		return this.server.prepareRename(this.doc, offset, (s: Span | null, error: string | null): void => {
			done(s === null ? null : [(s as Span).from, (s as Span).to], error);
		});
	}

	rename(offset: int32, name: string, done: (edits: Edit[] | null, others: int32, error: string | null) => void): int32 {
		return this.server.rename(this.doc, offset, name, done);
	}

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
