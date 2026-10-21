export const SWITCHER_DELAY_MS: float64 = 300;

export class Switcher {
	selected: int32 = 0;
	private count: int32 = 0;
	private held: boolean = false;
	private since: float64 = 0;

	open(count: int32, last: boolean, now: float64): void {
		this.count = count;
		this.held = count > 0;
		this.since = now;
		this.selected = last ? Math.max(0, count - 1) : count > 1 ? 1 : 0;
	}

	holding(): boolean { return this.held; }

	shown(now: float64): boolean { return this.held && now - this.since >= SWITCHER_DELAY_MS; }

	move(forward: boolean): void {
		if (!this.held || this.count == 0) { return; }
		this.selected = (this.selected + (forward ? 1 : this.count - 1)) % this.count;
	}

	released(): int32 | null {
		if (!this.held) { return null; }
		this.held = false;
		return this.selected;
	}

	cancel(): void { this.held = false; }
}

when (testBuild) {
	test "ctrl+tab starts on the tab used before this one, and ctrl+shift+tab on the least recent" {
		const s = new Switcher();
		s.open(3, false, 0);
		assert s.selected == 1 && s.holding();
		s.open(3, true, 0);
		assert s.selected == 2;
		s.open(1, false, 0);
		assert s.selected == 0;
	}

	test "tabs pressed while ctrl is held step through the list and wrap, and letting go picks the selected one" {
		const s = new Switcher();
		s.open(3, false, 0);
		s.move(true);
		s.move(true);
		assert s.selected == 0;
		s.move(false);
		assert s.selected == 2;
		assert s.released() == 2 && !s.holding() && s.released() === null;
	}

	test "the list shows only once ctrl has been held a moment, and a cancel picks nothing" {
		const s = new Switcher();
		s.open(2, false, 1000);
		assert !s.shown(1100) && s.shown(1300);
		s.cancel();
		assert !s.shown(2000) && s.released() === null;
	}
}
