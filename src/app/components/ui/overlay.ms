import { NeonNode } from "../../../../../neon/src/render/node";
import { Accessor } from "../../../../../neon/src/core/signal";
import { View } from "../../../../../neon/src/components/primitives";

export struct Box {
	x: float64;
	y: float64;
	width: float64;
	height: float64;
	color: string;
}

export function Overlay(props: {
	box: Accessor<Box>;
	shown?: Accessor<boolean> | null;
}): NeonNode {
	const shown = props.shown;
	return <View
		style={{
			position: "absolute",
			left: props.box().x,
			top: props.box().y,
			width: props.box().width,
			height: props.box().height,
			backgroundColor: props.box().color,
			opacity: shown === null || (shown as Accessor<boolean>)() ? 1 : 0,
			pointerEvents: "none",
		}}
	/>;
}
