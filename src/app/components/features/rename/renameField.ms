import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { Accessor } from "../../../../../../neon/src/core/signal";
import { onSettled } from "../../../../../../neon/src/core/effect";
import { Cleanup } from "../../../../../../neon/src/core/types";
import { Show } from "../../../../../../neon/src/macros/ui/flow";
import { createStyles, styleOf } from "../../../../../../neon/src/macros/ui/style";
import { TextInput, TextInputHandle, TextSelection, View } from "../../../../../../neon/src/components/primitives";
import { FIELD, FONT_SIZE, FOREGROUND } from "../../../theme";
import { Box } from "../../ui/overlay";

const styles = createStyles({
	field: {
		height: 26,
		paddingLeft: 6,
		backgroundColor: FIELD,
		color: FOREGROUND,
		fontSize: FONT_SIZE,
	},
});

export function RenameField(props: {
	shown: Accessor<boolean>;
	box: Accessor<Box>;
	name: Accessor<string>;
	selection: Accessor<TextSelection>;
	changed: (text: string) => void;
	confirmed: () => void;
	cancelled: () => void;
}): NeonNode {
	const key = (e: NeonEvent): void => {
		match (e.key) {
			"Escape" => { props.cancelled(); }
			"Enter" => { props.confirmed(); }
			_ => {}
		}
	};
	return <Show when={props.shown()}>
		<View style={{ position: "absolute", left: props.box().x, top: props.box().y, width: props.box().width }}>
			<TextInput
				style={styles.field}
				value={props.name()}
				selection={props.selection()}
				ref={(input: TextInputHandle): void => { onSettled((): Cleanup | null => { input.focus(); return null; }); }}
				onChangeText={props.changed}
				onKeyDown={key}
			/>
		</View>
	</Show>;
}
