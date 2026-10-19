import { element } from "../../../neon/src/macros/ui/element";
import { NeonNode } from "../../../neon/src/render/node";
import { NeonEvent } from "../../../neon/src/render/event";
import { Accessor, createSignal } from "../../../neon/src/core/signal";
import { createList, List } from "../../../neon/src/core/list";
import { ForList } from "../../../neon/src/macros/ui/flow";
import { PixelRatio } from "../../../neon/src/api/pixelRatio";
import { TextSpan } from "../../../neon/src/render/hostTypes";
import { Void, View, Text, ViewHandle } from "../../../neon/src/components/primitives";
import { Viewport } from "../view/viewport";

const BACKGROUND = "#1e1e2e";
const FOREGROUND = "#cdd6f4";
const PADDING: number = 6;
const FONT_SIZE: number = 14;
const PROBE = "MMMMMMMMMM";

export interface Lines {
	count: () => int32;
	at: (index: int32) => string;
}

export function linesOf(text: string): Lines {
	const all = text.split("\r\n").join("\n").split("\n");
	return {
		count: (): int32 => all.length as int32,
		at: (index: int32): string => all[index],
	};
}

export struct Row {
	spans: TextSpan[];
}

function rowOf(text: string): Row {
	return { spans: [{ text, style: { color: FOREGROUND } }] };
}

export function App(lines: Lines, fail: (message: string) => void): NeonNode {
	let area: ViewHandle | null = null;
	let view: Viewport = { top: 0, rows: 0, pending: 0 };
	const [cellWidth, setCellWidth] = createSignal<number>(0);
	const [rowHeight, setRowHeight] = createSignal<number>(0);
	const rows: List<Row> = createList<Row>([]);

	const paint = (): void => {
		const count = lines.count();
		while (rows.length() > view.rows) { rows.remove(rows.length() - 1); }
		for (let i = 0; i < view.rows; i++) {
			const line = view.top + i;
			const row = rowOf(line < count ? lines.at(line) : "");
			if (i < rows.length()) { rows.set(i, row); } else { rows.push(row); }
		}
	};

	const layout = (e: NeonEvent): void => {
		if (e.width <= 0 || e.height <= 0) { return; }
		const handle = area;
		if (handle === null) {
			fail("the editor laid out before its handle arrived");
			return;
		}
		const probe = handle.measureText(PROBE, { fontSize: FONT_SIZE });
		const ratio = PixelRatio.get();
		const cellPx = Math.round(probe.width / PROBE.length * ratio);
		const rowPx = Math.round(probe.height * ratio);
		if (cellPx <= 0 || rowPx <= 0) {
			fail(`cell ${probe.width / PROBE.length}x${probe.height} is not a grid size`);
			return;
		}
		setCellWidth(cellPx / ratio);
		setRowHeight(rowPx / ratio);
		const heightPx = PixelRatio.getPixelSizeForLayoutSize(e.height);
		view = view.resized(Math.floor(heightPx / rowPx) as int32, lines.count());
		paint();
	};

	const wheeled = (e: NeonEvent): void => {
		const next = view.wheeled(e.deltaY, lines.count());
		const moved = next.top != view.top;
		view = next;
		if (moved) { paint(); }
	};

	const lineRow = (item: Accessor<Row>): NeonNode => {
		return element(
			<Text
				style={{ fontSize: FONT_SIZE, height: rowHeight() }}
				cellWidth={cellWidth()}
				spans={item().spans}
			/>
		);
	};

	return element(
		<Void style={{ backgroundColor: BACKGROUND, padding: PADDING }}>
			<View
				style={{ flexGrow: 1, flexShrink: 1, flexBasis: 0 }}
				focusable
				ref={(h: ViewHandle): void => {
					area = h;
					h.focus();
				}}
				onLayout={layout}
				onWheel={wheeled}>
				{ForList<Row>({ each: rows, children: lineRow })}
			</View>
		</Void>
	);
}
