import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { createStyles, styleOf } from "../../../../../../neon/src/macros/ui/style";
import { Show } from "../../../../../../neon/src/macros/ui/flow";
import { Text, View } from "../../../../../../neon/src/components/primitives";
import { MUTED, PADDING, PANEL } from "../../../theme";
import { Field } from "../../ui/field";
import { Finder } from "./finder";

const styles = createStyles({
	panel: {
		position: "absolute",
		top: 0,
		right: PADDING * 2,
		width: 360,
		padding: 6,
		gap: 4,
		backgroundColor: PANEL,
	},
	note: { fontSize: 12, color: MUTED },
});

export function FindBar(props: {
	finder: Finder;
	moved: () => void;
	closed: () => void;
}): NeonNode {
	const finder = props.finder;
	const close = (): void => {
		finder.close();
		props.closed();
	};
	const findKey = (e: NeonEvent): void => {
		match (e.key) {
			"Escape" => { close(); }
			"Enter" | "F3" => {
				finder.again(e.shiftKey);
				props.moved();
			}
			_ => {}
		}
	};
	const replaceKey = (e: NeonEvent): void => {
		match (e.key) {
			"Escape" => { close(); }
			"Enter" => {
				if (e.ctrlKey && e.altKey) { finder.replaceEvery(); }
				else { finder.replace(); }
				props.moved();
			}
			_ => {}
		}
	};
	return <Show when={finder.shown()}>
		<View style={styles.panel}>
			<Field
				value={finder.query()}
				placeholder="Find"
				ref={finder.attach}
				onChangeText={(text: string): void => {
					finder.search(text);
					props.moved();
				}}
				onKeyDown={findKey}
			/>
			<Show when={finder.replacing()}>
				<Field
					value={finder.replacement()}
					placeholder="Replace"
					onChangeText={finder.setReplacement}
					onKeyDown={replaceKey}
				/>
			</Show>
			<Text style={styles.note}>{finder.note()}</Text>
		</View>
	</Show>;
}
