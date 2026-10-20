import { NeonNode } from "../../../neon/src/render/node";
import { Void } from "../../../neon/src/components/primitives";
import { Document } from "../model/document";
import { Editor } from "../model/editor";
import { lineCommentOf } from "../model/language";
import { Clip } from "../model/commands";
import { Syntax, covers } from "../syntax/syntax";
import { BACKGROUND, PADDING } from "./theme";
import { EditorPane } from "./components/features/editor/editorPane";

const HIGHLIGHT_LIMIT: int32 = 512 * 1024;

export function App(
	text: string,
	path: string,
	clip: Clip,
	store: (text: string) => string | null,
	fail: (message: string) => void,
): NeonNode {
	const editor = new Editor(new Document(text));
	editor.lineComment = lineCommentOf(path);
	const syntax = covers(path) && editor.doc.length() <= HIGHLIGHT_LIMIT ? new Syntax() : null;
	return <Void style={{ backgroundColor: BACKGROUND, padding: PADDING }}>
		<EditorPane
			editor={editor}
			path={path}
			syntax={syntax}
			clip={clip}
			save={store}
			fail={fail}
		/>
	</Void>;
}
