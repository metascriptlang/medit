function indexIn(list: string[], key: string): int32 {
	for (let i = 0; i < (list.length as int32); i++) {
		if (list[i] == key) { return i; }
	}
	return -1;
}

function without(list: string[], key: string): string[] {
	const kept: string[] = [];
	for (const k of list) {
		if (k != key) { kept.push(k); }
	}
	return kept;
}

export class Tabs {
	private list: string[] = [];
	private at: int32 = -1;
	private history: string[] = [];

	keys(): string[] { return this.list.slice(0, this.list.length); }

	active(): string | null { return this.at < 0 ? null : this.list[this.at]; }

	activeIndex(): int32 { return this.at; }

	recent(): string[] { return this.history.slice(0, this.history.length); }

	open(key: string): boolean {
		const found = indexIn(this.list, key);
		if (found >= 0) {
			this.activate(found);
			return false;
		}
		const insertAt = this.at + 1;
		const grown: string[] = [];
		for (let i = 0; i < (this.list.length as int32); i++) {
			if (i == insertAt) { grown.push(key); }
			grown.push(this.list[i]);
		}
		if (insertAt == (this.list.length as int32)) { grown.push(key); }
		this.list = grown;
		this.activate(insertAt);
		return true;
	}

	activate(index: int32): void {
		if (index < 0 || index >= (this.list.length as int32)) { return; }
		this.at = index;
		const key = this.list[index];
		const order: string[] = [key];
		for (const k of this.history) {
			if (k != key) { order.push(k); }
		}
		this.history = order;
	}

	next(): void {
		const n = this.list.length as int32;
		if (n > 0) { this.activate(this.at + 1 < n ? this.at + 1 : 0); }
	}

	previous(): void {
		const n = this.list.length as int32;
		if (n > 0) { this.activate(this.at > 0 ? this.at - 1 : n - 1); }
	}

	close(key: string): string | null {
		const index = indexIn(this.list, key);
		if (index < 0) { return this.active(); }
		const wasActive = index == this.at;
		this.history = without(this.history, key);
		this.list = without(this.list, key);
		if (this.list.length == 0) {
			this.at = -1;
			return null;
		}
		if (!wasActive) {
			if (index < this.at) { this.at -= 1; }
			return this.active();
		}
		const latest = this.history.length > 0 ? indexIn(this.list, this.history[0]) : -1;
		this.activate(latest >= 0 ? latest : Math.max(0, index - 1));
		return this.active();
	}

	rename(from: string, to: string): void {
		const index = indexIn(this.list, from);
		if (index < 0 || from == to) { return; }
		const taken = indexIn(this.list, to);
		const activeKey = taken == this.at ? from : this.active() as string;
		if (taken >= 0) {
			this.list = without(this.list, to);
			this.history = without(this.history, to);
		}
		this.list = this.list.map((k: string): string => k == from ? to : k);
		this.history = this.history.map((k: string): string => k == from ? to : k);
		this.at = indexIn(this.list, activeKey == from ? to : activeKey);
	}
}

when (testBuild) {
	function joined(tabs: Tabs): string { return tabs.keys().join(","); }

	test "a new tab opens right after the active one and becomes active" {
		const tabs = new Tabs();
		assert tabs.active() === null && tabs.activeIndex() == -1;
		assert tabs.open("a") && tabs.open("b") && tabs.open("c");
		assert joined(tabs) == "a,b,c" && tabs.active() == "c";
		tabs.activate(0);
		assert tabs.open("d");
		assert joined(tabs) == "a,d,b,c" && tabs.activeIndex() == 1;
	}

	test "opening a key already open activates it in place" {
		const tabs = new Tabs();
		tabs.open("a");
		tabs.open("b");
		tabs.open("c");
		assert !tabs.open("a");
		assert joined(tabs) == "a,b,c" && tabs.active() == "a";
		assert tabs.recent().join(",") == "a,c,b";
	}

	test "closing the active tab activates the one activated most recently" {
		const tabs = new Tabs();
		tabs.open("a");
		tabs.open("b");
		tabs.open("c");
		tabs.activate(0);
		tabs.activate(2);
		assert tabs.close("c") == "a";
		assert joined(tabs) == "a,b" && tabs.activeIndex() == 0;
		assert tabs.close("b") == "a" && tabs.activeIndex() == 0;
		assert tabs.close("x") == "a";
		assert tabs.close("a") === null && tabs.activeIndex() == -1 && tabs.recent().length == 0;
	}

	test "closing a tab left of the active one keeps the active tab" {
		const tabs = new Tabs();
		tabs.open("a");
		tabs.open("b");
		tabs.open("c");
		assert tabs.close("a") == "c" && tabs.activeIndex() == 1;
	}

	test "next and previous wrap around, and an index out of range changes nothing" {
		const tabs = new Tabs();
		tabs.next();
		tabs.previous();
		assert tabs.active() === null;
		tabs.open("a");
		tabs.open("b");
		tabs.open("c");
		tabs.next();
		assert tabs.active() == "a";
		tabs.previous();
		assert tabs.active() == "c";
		tabs.previous();
		assert tabs.active() == "b";
		tabs.activate(7);
		tabs.activate(-1);
		assert tabs.active() == "b";
	}

	test "rename keeps the position, the history and the active tab, and merges onto an open key" {
		const tabs = new Tabs();
		tabs.open("a");
		tabs.open("b");
		tabs.open("c");
		tabs.rename("b", "x");
		assert joined(tabs) == "a,x,c" && tabs.active() == "c";
		assert tabs.recent().join(",") == "c,x,a";
		tabs.rename("c", "a");
		assert joined(tabs) == "x,a" && tabs.active() == "a";
		assert tabs.recent().join(",") == "a,x";
		tabs.activate(0);
		tabs.rename("a", "x");
		assert joined(tabs) == "x" && tabs.active() == "x";
	}
}
