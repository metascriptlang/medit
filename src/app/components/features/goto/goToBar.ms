import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { Accessor } from "../../../../../../neon/src/core/signal";
import { createStyles, styleOf } from "../../../../../../neon/src/macros/ui/style";
import { Show } from "../../../../../../neon/src/macros/ui/flow";
import { TextInputHandle, View } from "../../../../../../neon/src/components/primitives";
import { PADDING, PANEL } from "../../../theme";
import { Field } from "../../ui/field";

const styles = createStyles({
	panel: {
		position: "absolute",
		top: 0,
		right: PADDING * 2,
		width: 200,
		padding: 6,
		backgroundColor: PANEL,
	},
});

export function GoToBar(props: {
	shown: Accessor<boolean>;
	query: Accessor<string>;
	attach: (input: TextInputHandle) => void;
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
		<View style={styles.panel}>
			<Field
				value={props.query()}
				placeholder="line:character"
				ref={props.attach}
				onChangeText={props.changed}
				onKeyDown={key}
			/>
		</View>
	</Show>;
}
