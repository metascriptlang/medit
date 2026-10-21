import { onSettled } from "../../../../../../neon/src/core/effect";
import { Cleanup } from "../../../../../../neon/src/core/types";
import { NeonNode } from "../../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../../neon/src/render/event";
import { createStyles, styleOf } from "../../../../../../neon/src/macros/ui/style";
import { Show } from "../../../../../../neon/src/macros/ui/flow";
import { Text, TextInputHandle, View } from "../../../../../../neon/src/components/primitives";
import { TextSpan } from "../../../../../../neon/src/render/hostTypes";
import { FOREGROUND, MUTED, PADDING, PANEL } from "../../../theme";
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

function status(finder: Finder, moved: () => void): TextSpan[] {
	const toggle = (label: string, on: boolean, flip: () => void): TextSpan => ({
		text: label,
		style: { color: on ? FOREGROUND : MUTED },
		onPress: (e: NeonEvent): void => {
			flip();
			moved();
		},
	});
	return [
		{ text: `${finder.note()}   ` },
		toggle("Aa", finder.caseSensitive(), finder.toggleCase),
		{ text: " " },
		toggle("Word", finder.wholeWord(), finder.toggleWord),
	];
}

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
			"Enter" when e.altKey => {
				finder.selectAll();
				props.moved();
				props.closed();
			}
			"Enter" | "F3" => {
				finder.again(e.shiftKey);
				props.moved();
			}
			"c" when e.altKey => {
				finder.toggleCase();
				props.moved();
			}
			"w" when e.altKey => {
				finder.toggleWord();
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
				ref={(input: TextInputHandle): void => { onSettled((): Cleanup | null => { finder.attach(input); return null; }); }}
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
			<Text
				style={styles.note}
				spans={status(finder, props.moved)}
			/>
		</View>
	</Show>;
}
