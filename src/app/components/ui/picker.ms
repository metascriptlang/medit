import { NeonNode } from "../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../neon/src/render/event";
import { Accessor } from "../../../../../neon/src/core/signal";
import { List } from "../../../../../neon/src/core/list";
import { ForList, Show } from "../../../../../neon/src/macros/ui/flow";
import { TextInputHandle, View } from "../../../../../neon/src/components/primitives";
import { MenuMove } from "../../../model/completer";
import { PANEL } from "../../theme";
import { Field } from "./field";
import { Box, Overlay } from "./overlay";
import { LineRow, Row } from "../content/lineRow";

export const PICKER_ROWS: int32 = 16;
export const PICKER_PADDING: float64 = 6;
export const PICKER_GAP: float64 = 4;

export function Picker(props: {
	placeholder: string;
	shown: Accessor<boolean>;
	box: Accessor<Box>;
	selected: Accessor<Box>;
	rows: List<Row>;
	query: Accessor<string>;
	cellWidth: Accessor<float64>;
	rowHeight: Accessor<float64>;
	attach: (input: TextInputHandle) => void;
	changed: (text: string) => void;
	moved: (m: MenuMove) => void;
	confirmed: () => void;
	cancelled: () => void;
}): NeonNode {
	const key = (e: NeonEvent): void => {
		match (e.key) {
			"ArrowUp" => { props.moved(MenuMove.Previous); }
			"ArrowDown" => { props.moved(MenuMove.Next); }
			"PageUp" => { props.moved(MenuMove.First); }
			"PageDown" => { props.moved(MenuMove.Last); }
			"Enter" => { props.confirmed(); }
			"Escape" => { props.cancelled(); }
			_ => {}
		}
	};
	return <Show when={props.shown()}>
		<View
			style={{
				position: "absolute",
				left: props.box().x,
				top: props.box().y,
				width: props.box().width,
				padding: PICKER_PADDING,
				backgroundColor: PANEL,
			}}>
			<Field
				value={props.query()}
				placeholder={props.placeholder}
				ref={props.attach}
				onChangeText={props.changed}
				onKeyDown={key}
			/>
			<View style={{ height: props.box().height, marginTop: PICKER_GAP, overflow: "hidden" }}>
				<Overlay box={props.selected()} />
				{ForList<Row>({
					each: props.rows,
					children: (r: Accessor<Row>): NeonNode => <LineRow
						row={r()}
						cellWidth={props.cellWidth()}
						rowHeight={props.rowHeight()}
					/>,
				})}
			</View>
		</View>
	</Show>;
}
