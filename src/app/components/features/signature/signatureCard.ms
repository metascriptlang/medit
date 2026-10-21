import { SignatureHelp } from "../../../../model/signatures";
import { PANEL } from "../../../theme";
import { Box } from "../../ui/overlay";
import { Card, Highlight, cardOf, cardSize } from "../hover/hoverCard";

const FENCE = "```";
const MAX_COLUMNS: int32 = 120;
const MIN_COLUMNS: int32 = 20;
const MAX_ROWS: int32 = 16;
const MIN_ROWS: int32 = 4;
const GAP: float64 = 10;
const RIGHT_MARGIN: float64 = 8;

// The shown signature as a card: its label in the file's language with the active parameter
// underlined, then that parameter's documentation and the signature's, each under a rule; a
// count heads it while there are several signatures. It takes at most half the editor's width
// and height, and no less than 20 columns and 4 rows.
export function signatureCard(help: SignatureHelp, current: int32, language: string, columns: int32, rows: int32, highlight: Highlight): Card {
	const s = help.signatures[current];
	const parts: string[] = [];
	const n = help.signatures.length as int32;
	if (n > 1) { parts.push(`${current + 1}/${n}`); }
	parts.push(`${FENCE}${language}\n${s.label}\n${FENCE}`);
	const p = s.active >= 0 && s.active < (s.parameters.length as int32) ? s.parameters[s.active] : null;
	if (p !== null && p.documentation.trim().byteLength > 0) { parts.push(`---\n${p.documentation}`); }
	if (s.documentation.trim().byteLength > 0) { parts.push(`---\n${s.documentation}`); }
	const emphasis = p !== null && p.from >= 0 ? [p.from, p.to] : [];
	const width = Math.max(MIN_COLUMNS, Math.min(MAX_COLUMNS, Math.floor(columns / 2) as int32));
	const card = cardOf([], parts.join("\n"), width, highlight, emphasis);
	const height = Math.max(MIN_ROWS, Math.min(MAX_ROWS, Math.floor(rows / 2) as int32));
	return { rows: card.rows.slice(0, height), columns: card.columns };
}

function overlaps(a: Box, b: Box | null): boolean {
	if (b === null) { return false; }
	const m = b as Box;
	return a.x < m.x + m.width && m.x < a.x + a.width && a.y < m.y + m.height && m.y < a.y + a.height;
}

function within(b: Box, areaWidth: float64, areaHeight: float64): boolean {
	return b.x >= 0 && b.y >= 0 && b.x + b.width <= areaWidth && b.y + b.height <= areaHeight;
}

// Above the cursor's row, else below it, wherever it stays inside the editor clear of the
// completion menu; else beside or above or below the menu; else above or below the row anyway.
export function signaturePlaced(card: Card, x: float64, rowTop: float64, rowHeight: float64, cellWidth: float64, areaWidth: float64, areaHeight: float64, menu: Box | null): Box {
	const [width, height] = cardSize(card, rowHeight, cellWidth);
	const left = x + Math.min(0, areaWidth - RIGHT_MARGIN - (x + width));
	const at = (bx: float64, by: float64): Box => ({ x: bx, y: by, width, height, color: PANEL });
	const above = at(left, rowTop - height);
	const below = at(left, rowTop + rowHeight + GAP);
	if (within(above, areaWidth, areaHeight) && !overlaps(above, menu)) { return above; }
	if (within(below, areaWidth, areaHeight) && !overlaps(below, menu)) { return below; }
	if (menu !== null) {
		const m = menu as Box;
		const around = [
			at(m.x - width - GAP, m.y),
			at(m.x + m.width + GAP, m.y),
			at(m.x, m.y - height - GAP),
			at(m.x, m.y + m.height + GAP),
		];
		for (const b of around) {
			if (within(b, areaWidth, areaHeight)) { return b; }
		}
	}
	return within(above, areaWidth, areaHeight) ? above : below;
}

when (testBuild) {
	import { Parameter, Signature } from "../../../../model/signatures";
	import { Tone } from "../../../../view/tone";

	const plain = (source: string, language: string): Tone[] | null => null;

	function signature(label: string, parameters: Parameter[], active: int32, documentation: string): Signature {
		return { label, documentation, parameters, active };
	}

	test "the card underlines the active parameter and lists its documentation before the signature's" {
		const s = signature("f(a: int32, b: string): void", [
			{ from: 2, to: 10, documentation: "" },
			{ from: 12, to: 21, documentation: "the name" },
		], 1, "Greets.");
		const card = signatureCard({ signatures: [s], active: 0, raw: "" }, 0, "ms", 200, 40, plain);
		const label = card.rows[0].spans;
		assert label.length == 3 && label[1].text == "b: string" && label[1].style.textDecorationLine == "underline";
		assert label[0].text == "f(a: int32, " && label[0].style.textDecorationLine === undefined;
		assert card.rows[2].spans[0].text == "the name" && card.rows[4].spans[0].text == "Greets.";
		const two = signatureCard({ signatures: [s, signature("f()", [], 0, "")], active: 0, raw: "" }, 1, "ms", 200, 40, plain);
		assert two.rows[0].spans[0].text == "2/2" && two.rows[1].spans[0].text == "f()";
	}

	test "the card sits above the row, below it when the menu or the top is in the way, and beside the menu last" {
		const card: Card = { rows: [{ spans: [] }, { spans: [] }], columns: 8 };
		const up = signaturePlaced(card, 100, 100, 20, 10, 1000, 600, null);
		assert up.y == 100 - 42 && up.x == 100 && up.width == 102;
		const pushed = signaturePlaced(card, 950, 100, 20, 10, 1000, 600, null);
		assert pushed.x == 1000 - 8 - 102;
		const down = signaturePlaced(card, 100, 20, 20, 10, 1000, 600, null);
		assert down.y == 50;
		const menu: Box = { x: 100, y: 0, width: 200, height: 600, color: "" };
		const beside = signaturePlaced(card, 100, 100, 20, 10, 1000, 600, menu);
		assert beside.x == 310 && beside.y == 0;
	}
}
