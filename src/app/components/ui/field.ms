import { NeonNode } from "../../../../../neon/src/render/node";
import { NeonEvent } from "../../../../../neon/src/render/event";
import { Accessor } from "../../../../../neon/src/core/signal";
import { createStyles, styleOf } from "../../../../../neon/src/macros/ui/style";
import { TextInput, TextInputHandle } from "../../../../../neon/src/components/primitives";
import { FIELD, FONT_SIZE, FOREGROUND, MUTED } from "../../theme";

const styles = createStyles({
	field: {
		height: 26,
		paddingLeft: 6,
		backgroundColor: FIELD,
		color: FOREGROUND,
		fontSize: FONT_SIZE,
	},
});

export function Field(props: {
	value: Accessor<string>;
	placeholder: string;
	onChangeText: (text: string) => void;
	onKeyDown: (e: NeonEvent) => void;
	ref?: ((input: TextInputHandle) => void) | null;
}): NeonNode {
	return <TextInput
		style={styles.field}
		value={props.value()}
		placeholder={props.placeholder}
		placeholderTextColor={MUTED}
		ref={props.ref}
		onChangeText={props.onChangeText}
		onKeyDown={props.onKeyDown}
	/>;
}
