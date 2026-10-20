import { Accessor, createSignal } from "../../../../../../neon/src/core/signal";

const BLINK_MS: float64 = 530;

export interface Blink {
	on: Accessor<boolean>;
	restart: () => void;
}

export function createBlink(): Blink {
	const [on, setOn] = createSignal<boolean>(true);
	let timer: float64 = -1;
	function arm(): void {
		timer = setTimeout((): void => {
			setOn(!on());
			arm();
		}, BLINK_MS);
	}
	return {
		on,
		restart: (): void => {
			if (timer >= 0) { clearTimeout(timer); }
			setOn(true);
			arm();
		},
	};
}
