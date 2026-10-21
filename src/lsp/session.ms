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
import { sameFile } from "./uri";

export interface Link {
	send: (bytes: string) => boolean;
	take: () => string;
	ended: () => boolean;
	stop: () => void;
	listen: (ready: () => void) => void;
}

export class Session {
	readonly name: string;
	readonly uri: string;
	readonly diagnostics: Diagnostics = new Diagnostics();
	private server: Server;
	private doc: Document;
	private open: boolean = true;
	private shown: () => string;
	private forget: (s: Session) => void;
	private watchers: Array<() => void> = [];
	private editing: (edits: Edit[], others: int32) => string | null = (edits: Edit[], others: int32): string | null => "nothing applies edits yet";

	constructor(server: Server, name: string, doc: Document, uri: string, languageId: string, shown: () => string, forget: (s: Session) => void) {
		this.server = server;
		this.name = name;
		this.doc = doc;
		this.uri = uri;
		this.shown = shown;
		this.forget = forget;
		server.open(doc, uri, languageId);
		server.applyEdits(doc, (edits: Edit[], others: int32): string | null => this.editing(edits, others));
	}

	changed(): void {
		for (const w of this.watchers) { w(); }
	}

	watch(handler: () => void): void { this.watchers.push(handler); }

	diagnosed(params: JsonValue): boolean {
		if (!this.open) { return false; }
		const found = this.server.diagnosticsOf(this.doc, params);
		if (found === null) { return false; }
		this.diagnostics.replace(this.doc, found as Diagnostic[]);
		return true;
	}

	ended(): void { this.diagnostics.replace(this.doc, []); }

	close(): void {
		if (!this.open) { return; }
		this.open = false;
		this.server.close(this.doc);
		this.diagnostics.replace(this.doc, []);
		this.forget(this);
	}

	status(): string { return this.shown(); }

	ready(): boolean { return this.open && this.server.ready(); }

	edited(): void { this.server.changed(this.doc); }

	saved(): void { this.server.saved(this.doc); }

	hover(offset: int32, done: (text: string, over: Span | null) => void): int32 {
		return this.server.hover(this.doc, offset, done);
	}

	definition(offset: int32, done: (found: Target[]) => void): int32 {
		return this.server.definition(this.doc, offset, (found: Target[]): void => {
			done(found.map((t: Target): Target => sameFile(t.uri, this.uri) ? t : { uri: t.uri, range: t.range, here: null }));
		});
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
				here: t.here === null || !sameFile(t.uri, this.uri) ? null : [(t.here as Span).from, (t.here as Span).to],
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

	// Who applies the edits to this document that the server asks for on its own, or that an
	// answer to another open document's request carries.
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
}
