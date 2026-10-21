import { CodeAction } from "../../../../model/actions";
import { FOREGROUND } from "../../../theme";
import { Row } from "../../content/lineRow";
import { cellsOf, clipped } from "../completion/completionMenu";

const MAX_COLUMNS: int32 = 80;

export function actionColumns(actions: CodeAction[]): int32 {
	let widest = 1;
	for (const a of actions) { widest = Math.max(widest, cellsOf(a.title)); }
	return Math.min(MAX_COLUMNS, widest);
}

// The titles of `count` actions from `top`, clipped to the list's width.
export function actionRows(actions: CodeAction[], top: int32, count: int32, columns: int32): Row[] {
	const rows: Row[] = [];
	const end = Math.min(actions.length as int32, top + count);
	for (let k = top; k < end; k++) {
		rows.push({ spans: [{ text: clipped(actions[k].title, columns), style: { color: FOREGROUND } }] });
	}
	return rows;
}

when (testBuild) {
	test "the list is as wide as its longest title, up to a limit, and rows clip to it" {
		const long = "x".repeat(100);
		const actions: CodeAction[] = [
			{ title: "Fix", kind: "quickfix", preferred: true, raw: "" },
			{ title: long, kind: "", preferred: false, raw: "" },
		];
		assert actionColumns(actions.slice(0, 1)) == 3 && actionColumns(actions) == 80;
		const rows = actionRows(actions, 1, 5, 80);
		assert rows.length == 1 && cellsOf(rows[0].spans[0].text) <= 80;
	}
}
