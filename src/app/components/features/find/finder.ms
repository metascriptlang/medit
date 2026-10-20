import { Accessor, createSignal } from "../../../../../../neon/src/core/signal";
import { TextInputHandle } from "../../../../../../neon/src/components/primitives";
import { Editor } from "../../../../model/editor";
import { replaceAll, replaceMatch, selectFirstMatch, selectMatch } from "../../../../model/find";
import { end, isEmpty, start } from "../../../../model/selection";

export interface Finder {
	shown: Accessor<boolean>;
	replacing: Accessor<boolean>;
	query: Accessor<string>;
	replacement: Accessor<string>;
	note: Accessor<string>;
	attach: (input: TextInputHandle) => void;
	open: (replace: boolean) => void;
	close: () => void;
	again: (backwards: boolean) => void;
	search: (text: string) => void;
	setReplacement: (text: string) => void;
	replace: () => void;
	replaceEvery: () => void;
}

export function createFinder(editor: Editor): Finder {
	const doc = editor.doc;
	const [shown, setShown] = createSignal<boolean>(false);
	const [replacing, setReplacing] = createSignal<boolean>(false);
	const [query, setQuery] = createSignal<string>("");
	const [replacement, setReplacement] = createSignal<string>("");
	const [note, setNote] = createSignal<string>("");
	let input: TextInputHandle | null = null;
	const found = (hit: boolean): void => { setNote(hit ? "" : "no match"); };
	const open = (replace: boolean): void => {
		const s = editor.selections.ranges[editor.selections.primary];
		if (!s.isEmpty() && doc.lineOf(s.start()) == doc.lineOf(s.end())) {
			setQuery(doc.slice(s.start(), s.end()));
		}
		setNote("");
		setReplacing(replace);
		setShown(true);
		if (input !== null) { (input as TextInputHandle).focus(); }
	};
	return {
		shown,
		replacing,
		query,
		replacement,
		note,
		attach: (handle: TextInputHandle): void => {
			input = handle;
			handle.focus();
		},
		open,
		close: (): void => {
			setShown(false);
			input = null;
		},
		again: (backwards: boolean): void => {
			if (query() == "") { open(false); }
			else { found(selectMatch(editor, query(), backwards)); }
		},
		search: (text: string): void => {
			setQuery(text);
			if (text == "") { setNote(""); }
			else { found(selectFirstMatch(editor, text)); }
		},
		setReplacement: (text: string): void => { setReplacement(text); },
		replace: (): void => {
			if (query() != "") { found(replaceMatch(editor, query(), replacement())); }
		},
		replaceEvery: (): void => {
			if (query() == "") { return; }
			const n = replaceAll(editor, query(), replacement());
			setNote(n == 1 ? "1 replaced" : `${n} replaced`);
		},
	};
}
