import { NeonNode } from "../../../neon/src/render/node";
import { Void } from "../../../neon/src/components/primitives";
import { Document } from "../model/document";
import { Editor } from "../model/editor";
import { Language, blockCommentOf, languageOf, lineCommentOf } from "../model/language";
import { Clip } from "../model/commands";
import { Syntax, covers } from "../syntax/syntax";
import { Link, Session } from "../lsp/session";
import { BACKGROUND, PADDING } from "./theme";
import { EditorPane } from "./components/features/editor/editorPane";

const HIGHLIGHT_LIMIT: int32 = 512 * 1024;

export interface Connect {
	link: (command: string) => Link | null;
	uri: string;
	rootUri: string | null;
	processId: int32 | null;
}

export function App(
	text: string,
	path: string,
	clip: Clip,
	store: (text: string) => string | null,
	fail: (message: string) => void,
	connect: Connect | null,
): NeonNode {
	const editor = new Editor(new Document(text));
	editor.lineComment = lineCommentOf(path);
	editor.blockComment = blockCommentOf(path);
	const syntax = covers(path) && editor.doc.length() <= HIGHLIGHT_LIMIT ? new Syntax() : null;
	const language = languageOf(path);
	let session: Session | null = null;
	let serverNote = "";
	if (language !== null && connect !== null) {
		const { id, server } = language as Language;
		const c = connect as Connect;
		const link = c.link(server);
		if (link === null) {
			serverNote = `cannot start ${server}`;
		} else {
			session = new Session(link as Link, server, editor.doc, c.uri, id, c.rootUri, c.processId);
		}
	}
	return <Void style={{ backgroundColor: BACKGROUND, padding: PADDING }}>
		<EditorPane
			editor={editor}
			path={path}
			syntax={syntax}
			clip={clip}
			save={store}
			fail={fail}
			session={session}
			serverNote={serverNote}
		/>
	</Void>;
}
