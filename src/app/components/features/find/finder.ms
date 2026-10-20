import { Accessor, createSignal } from "../../../../../../neon/src/core/signal";
import { TextInputHandle } from "../../../../../../neon/src/components/primitives";
import { Editor } from "../../../../model/editor";
import {
	Query,
	allMatches,
	replaceAll,
	replaceMatch,
	selectAllMatches,
	selectFirstMatch,
	selectMatch,
} from "../../../../model/find";
import { end, isEmpty, primaryRange, start } from "../../../../model/selection";

export interface Finder {
	shown: Accessor<boolean>;
	replacing: Accessor<boolean>;
	query: Accessor<string>;
	replacement: Accessor<string>;
	caseSensitive: Accessor<boolean>;
	wholeWord: Accessor<boolean>;
	note: Accessor<string>;
	searched: () => Query | null;
	attach: (input: TextInputHandle) => void;
	open: (replace: boolean) => void;
	close: () => void;
	again: (backwards: boolean) => void;
	search: (text: string) => void;
	toggleCase: () => void;
	toggleWord: () => void;
	selectAll: () => void;
	setReplacement: (text: string) => void;
	replace: () => void;
	replaceEvery: () => void;
}

function placeOf(hits: int32[], at: int32): int32 {
	let lo = 0;
	let hi = hits.length as int32;
	while (lo < hi) {
		const mid = (lo + hi) >> 1;
		if (hits[mid] <= at) { lo = mid + 1; } else { hi = mid; }
	}
	return lo;
}

export function createFinder(editor: Editor): Finder {
	const doc = editor.doc;
	const [shown, setShown] = createSignal<boolean>(false);
	const [replacing, setReplacing] = createSignal<boolean>(false);
	const [query, setQuery] = createSignal<string>("");
	const [replacement, setReplacement] = createSignal<string>("");
	const [caseSensitive, setCaseSensitive] = createSignal<boolean>(editor.caseSensitive);
	const [wholeWord, setWholeWord] = createSignal<boolean>(false);
	const [note, setNote] = createSignal<string>("");
	let input: TextInputHandle | null = null;
	let open = false;
	let q: Query = { text: "", caseSensitive: editor.caseSensitive, wholeWord: false };
	let swap = "";
	const searched = (): Query | null => open && q.text != "" ? q : null;
	const count = (): void => {
		if (searched() === null) {
			setNote("");
			return;
		}
		const hits = doc.allMatches(q);
		if (hits.length == 0) {
			setNote("no match");
			return;
		}
		const at = placeOf(hits, editor.selections.primaryRange().start());
		setNote(`${Math.max(1, at)} of ${hits.length}`);
	};
	const first = (): void => {
		if (searched() !== null) { const _hit = editor.selectFirstMatch(q); }
		count();
	};
	const show = (replace: boolean): void => {
		const s = editor.selections.primaryRange();
		if (!s.isEmpty() && doc.lineOf(s.start()) == doc.lineOf(s.end())) {
			q = { ...q, text: doc.slice(s.start(), s.end()) };
			setQuery(q.text);
		}
		open = true;
		setReplacing(replace);
		setShown(true);
		count();
		if (input !== null) { (input as TextInputHandle).focus(); }
	};
	return {
		shown,
		replacing,
		query,
		replacement,
		caseSensitive,
		wholeWord,
		note,
		searched,
		attach: (handle: TextInputHandle): void => {
			input = handle;
			handle.focus();
		},
		open: show,
		close: (): void => {
			open = false;
			setShown(false);
			input = null;
		},
		again: (backwards: boolean): void => {
			if (searched() === null) { show(false); }
			else {
				const _hit = editor.selectMatch(q, backwards);
				count();
			}
		},
		search: (text: string): void => {
			q = { ...q, text };
			setQuery(text);
			first();
		},
		toggleCase: (): void => {
			q = { ...q, caseSensitive: !q.caseSensitive };
			editor.caseSensitive = q.caseSensitive;
			setCaseSensitive(q.caseSensitive);
			first();
		},
		toggleWord: (): void => {
			q = { ...q, wholeWord: !q.wholeWord };
			setWholeWord(q.wholeWord);
			first();
		},
		selectAll: (): void => {
			if (searched() !== null) { const _n = editor.selectAllMatches(q); }
		},
		setReplacement: (text: string): void => {
			swap = text;
			setReplacement(text);
		},
		replace: (): void => {
			if (searched() === null) { return; }
			const _hit = editor.replaceMatch(q, swap);
			count();
		},
		replaceEvery: (): void => {
			if (searched() === null) { return; }
			const n = editor.replaceAll(q, swap);
			setNote(n == 1 ? "1 replaced" : `${n} replaced`);
		},
	};
}
