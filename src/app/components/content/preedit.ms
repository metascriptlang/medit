import { NeonNode } from "../../../../../neon/src/render/node";
import { Accessor } from "../../../../../neon/src/core/signal";
import { Text, View } from "../../../../../neon/src/components/primitives";
import { BACKGROUND, FONT_SIZE, FOREGROUND } from "../../theme";
import { Box } from "../ui/overlay";

export function Preedit(props: {
	text: Accessor<string>;
	at: Accessor<Box>;
	cellWidth: Accessor<float64>;
}): NeonNode {
	return <View
		style={{
			position: "absolute",
			left: props.at().x,
			top: props.at().y,
			backgroundColor: BACKGROUND,
			pointerEvents: "none",
		}}>
		<Text
			style={{
				fontSize: FONT_SIZE,
				color: FOREGROUND,
				height: props.at().height,
				textDecorationLine: "underline",
			}}
			cellWidth={props.cellWidth()}>
			{props.text()}
		</Text>
	</View>;
}
