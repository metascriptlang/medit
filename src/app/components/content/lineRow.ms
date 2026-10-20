import { NeonNode } from "../../../../../neon/src/render/node";
import { Accessor } from "../../../../../neon/src/core/signal";
import { TextSpan } from "../../../../../neon/src/render/hostTypes";
import { Text } from "../../../../../neon/src/components/primitives";
import { FONT_SIZE } from "../../theme";

export struct Row {
	spans: TextSpan[];
}

export function LineRow(props: {
	row: Accessor<Row>;
	cellWidth: Accessor<float64>;
	rowHeight: Accessor<float64>;
}): NeonNode {
	return <Text
		style={{ fontSize: FONT_SIZE, height: props.rowHeight() }}
		cellWidth={props.cellWidth()}
		spans={props.row().spans}
	/>;
}
