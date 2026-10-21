import { cellsIn } from "../text/clusters";

export const DETAIL_CELLS: int32 = 24;
const ELLIPSIS = "…";

export struct TabEntry {
	path: string;
	dirty: boolean;
}

export struct TabCell {
	index: int32;
	from: int32;
	to: int32;
	mark: int32;
	title: string;
	detail: string;
}

export struct TabHit {
	index: int32;
	close: boolean;
}

function partsOf(path: string): string[] {
	return path.replaceAll("\\", "/").split("/").filter((p: string): boolean => p.byteLength > 0);
}

function cellsOf(text: string): int32 {
	return cellsIn(text.asBytes(), 0, text.byteLength, 0);
}

export function titleOf(path: string): string {
	const parts = partsOf(path);
	return parts.length == 0 ? path : parts[parts.length - 1];
}

export function detailOf(path: string, level: int32): string {
	if (level <= 0) { return ""; }
	const parts = partsOf(path);
	const dirs = parts.slice(0, Math.max(0, parts.length - 1));
	const from = Math.max(0, dirs.length - level);
	const shown = dirs.slice(from).join("/");
	return shown.length > DETAIL_CELLS ? shown.slice(0, DETAIL_CELLS) + ELLIPSIS : shown;
}

export function tabDetails(paths: string[]): int32[] {
	const levels: int32[] = paths.map((p: string): int32 => 0);
	const shown: string[] = paths.map((p: string): string => titleOf(p));
	const settled: boolean[] = paths.map((p: string): boolean => false);
	while (true) {
		const seen = new Map<string, int32[]>();
		for (let i = 0; i < paths.length; i++) {
			if (settled[i]) { continue; }
			const key = shown[i];
			const at = seen.get(key);
			if (at === undefined) { seen.set(key, [i]); } else { (at as int32[]).push(i); }
		}
		let collided = false;
		for (const [key, indices] of seen) {
			if (indices.length < 2) { continue; }
			collided = true;
			for (const i of indices) {
				levels[i] += 1;
				const next = `${titleOf(paths[i])} ${detailOf(paths[i], levels[i])}`;
				if (next == shown[i]) { settled[i] = true; } else { shown[i] = next; }
			}
		}
		if (!collided) { return levels; }
	}
}

export function tabCells(entries: TabEntry[]): TabCell[] {
	const levels = tabDetails(entries.map((t: TabEntry): string => t.path));
	const out: TabCell[] = [];
	let at = 0;
	for (let i = 0; i < entries.length; i++) {
		const title = titleOf(entries[i].path);
		const detail = detailOf(entries[i].path, levels[i]);
		const inner = 1 + cellsOf(title) + (detail.byteLength > 0 ? 1 + cellsOf(detail) : 0) + 1;
		out.push({ index: i, from: at, to: at + inner + 2, mark: at + inner, title, detail });
		at += inner + 2;
	}
	return out;
}

export function stripLeft(cells: TabCell[], active: int32, left: int32, width: int32): int32 {
	if (cells.length == 0) { return 0; }
	const total = cells[cells.length - 1].to;
	let shown = Math.max(0, Math.min(left, total - width));
	if (active < 0 || active >= cells.length) { return shown; }
	const c = cells[active];
	if (c.from < shown) { shown = c.from; }
	if (c.to > shown + width) { shown = Math.max(0, c.to - width); }
	return shown;
}

export function tabAt(cells: TabCell[], column: int32): TabHit | null {
	for (const c of cells) {
		if (column >= c.from && column < c.to) { return { index: c.index, close: column == c.mark }; }
	}
	return null;
}

when (testBuild) {
	test "tabs show the file name, and a name two tabs share also shows enough of its directory to tell them apart" {
		const levels = tabDetails(["src/a/mod.ms", "src/b/mod.ms", "src/main.ms", "lib/b/mod.ms"]);
		assert levels[0] == 1 && levels[2] == 0;
		assert levels[1] == 2 && levels[3] == 2;
		assert detailOf("src/b/mod.ms", 2) == "src/b" && detailOf("lib/b/mod.ms", 2) == "lib/b";
		assert detailOf("src/a/mod.ms", 1) == "a";
	}

	test "the same path twice settles instead of looping, and a backslash path splits like a slash path" {
		const levels = tabDetails(["a/x.ms", "a/x.ms"]);
		assert levels[0] == levels[1];
		assert titleOf("C:\\work\\x.ms") == "x.ms" && detailOf("C:\\work\\x.ms", 1) == "work";
	}

	test "a long directory is cut to its first cells with an ellipsis" {
		assert detailOf("abcdefghijklmnopqrstuvwxyz0123/x.ms", 1) == "abcdefghijklmnopqrstuvwx…";
	}

	test "cells lay tabs side by side, and the mark cell closes" {
		const cells = tabCells([{ path: "a.ms", dirty: false }, { path: "bb.ms", dirty: true }]);
		assert cells[0].from == 0 && cells[0].mark == 6 && cells[0].to == 8;
		assert cells[1].from == 8 && cells[1].mark == 15 && cells[1].to == 17;
		const hit = tabAt(cells, 15) as TabHit;
		assert hit.index == 1 && hit.close;
		assert !(tabAt(cells, 2) as TabHit).close;
		assert tabAt(cells, 40) === null;
	}

	test "the strip scrolls just enough to show the active tab" {
		const cells = tabCells([{ path: "aaaa.ms", dirty: false }, { path: "bbbb.ms", dirty: false }, { path: "cccc.ms", dirty: false }]);
		assert stripLeft(cells, 0, 0, 15) == 0;
		assert stripLeft(cells, 2, 0, 15) == cells[2].to - 15;
		assert stripLeft(cells, 0, 20, 15) == 0;
		assert stripLeft(cells, 1, 10, 15) == 10;
		assert stripLeft(cells, 1, 12, 15) == 11;
	}
}
