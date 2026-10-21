import { Document, Edit } from "./document";
import { textDiff } from "../text/diff";

const NEWLINE: int32 = 10;

// A server's edits, offsets as the document is now, made precise: in document order (edits at
// one place keep the server's order), joined where they touch or lie one line break apart, and
// each edit that spans lines cut down to a diff of its old and new text, so the text a server
// rewrites unchanged keeps its cursors and anchors.
export function refined(doc: Document, edits: Edit[]): Edit[] {
	const order: Array<[Edit, int32]> = [];
	for (let i = 0; i < (edits.length as int32); i++) { order.push([edits[i], i]); }
	order.sort((a: [Edit, int32], b: [Edit, int32]) =>
		a[0].from != b[0].from ? a[0].from - b[0].from : a[0].to != b[0].to ? a[0].to - b[0].to : a[1] - b[1]);
	const out: Edit[] = [];
	let i = 0;
	while (i < (order.length as int32)) {
		let { from, to, text } = order[i][0];
		i += 1;
		while (i < (order.length as int32)) {
			const next = order[i][0];
			if (next.from > to) {
				if (next.from != to + 1 || doc.byteAt(to) != NEWLINE) { break; }
				text += "\n";
			}
			to = Math.max(to, next.to);
			text += next.text;
			i += 1;
		}
		if (doc.lineOf(from) == doc.lineOf(to)) {
			out.push({ from, to, text });
			continue;
		}
		for (const r of textDiff(doc.slice(from, to), text)) {
			out.push({ from: from + r.from, to: from + r.to, text: r.text });
		}
	}
	return out;
}

test "a whole-text rewrite becomes the few edits that change it" {
	const doc = new Document("let  a=1;\nkeep();\nb  =2;\n");
	const out = refined(doc, [{ from: 0, to: doc.length(), text: "let a = 1;\nkeep();\nb = 2;\n" }]);
	assert out.length > 1;
	for (const e of out) { assert e.to <= 9 || e.from >= 18; }
}

test "edits at one place keep their order, and touching or line-apart edits join" {
	const doc = new Document("ab\ncd\nef");
	const at = refined(doc, [{ from: 1, to: 1, text: "x" }, { from: 1, to: 1, text: "y" }, { from: 7, to: 8, text: "F" }]);
	assert at.length == 2 && at[0].from == 1 && at[0].text == "xy" && at[1].from == 7;
	const apart = refined(doc, [{ from: 3, to: 5, text: "CD" }, { from: 0, to: 2, text: "AB" }]);
	assert apart.length == 2 && apart[0].from == 0 && apart[0].to == 2 && apart[0].text == "AB";
	assert apart[1].from == 3 && apart[1].to == 5 && apart[1].text == "CD";
}
