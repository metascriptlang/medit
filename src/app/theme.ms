import { Tone } from "../view/tone";

export const BACKGROUND = "#1e1e2e";
export const FOREGROUND = "#cdd6f4";
export const MUTED = "#6c7086";
export const SELECTION = "#45475a";
export const MATCH = "#4a4536";
export const BRACKET = "#585b70";
export const CURRENT_LINE = "#2a2b3c";
export const CURRENT_NUMBER = "#bac2de";
export const CARET = "#f5e0dc";
export const PANEL = "#181825";
export const FIELD = "#313244";
export const PADDING: float64 = 6;
export const FONT_SIZE: float64 = 14;

export function colorOf(tone: Tone): string {
	return match (tone) {
		Tone.Plain | Tone.Variable => FOREGROUND,
		Tone.Keyword => "#cba6f7",
		Tone.Function | Tone.Tag => "#89b4fa",
		Tone.Type => "#f9e2af",
		Tone.String => "#a6e3a1",
		Tone.Number | Tone.Constant => "#fab387",
		Tone.Comment => "#7f849c",
		Tone.Operator => "#89dceb",
		Tone.Punctuation => "#9399b2",
		Tone.Parameter => "#eba0ac",
		Tone.Property => "#b4befe",
		Tone.Builtin => "#f38ba8",
		Tone.Attribute => "#f5c2e7",
	};
}
