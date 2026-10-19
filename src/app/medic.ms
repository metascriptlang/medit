import { NeonNode } from "../../../neon/src/render/node";
import { runWindow, DesktopOptions, desktopOptions } from "../../../neon/src/platform/ion/window";
import { argv, exit } from "std/process";
import { readFile } from "std/fs";
import { App, linesOf } from "./app";

const FONT_PATH = "assets/JetBrainsMonoNL-Regular.ttf";

function fail(message: string): void {
	console.log(`medic: ${message}`);
	exit(1);
}

function main(): int32 {
	if (argv.length < 2) {
		console.log("usage: medic <file>");
		return 2;
	}
	const path = argv[argv.length - 1];
	const text = readFile(path);
	if (!text.ok) {
		console.log(`medic: cannot read ${path}: ${text.error.toString()}`);
		return 1;
	}
	const lines = linesOf(text.value);
	const opts: DesktopOptions = { ...desktopOptions(`medic ${path}`, 960, 640), font: FONT_PATH };
	return runWindow(opts, (): NeonNode => App(lines, fail)) as int32;
}

exit(main());
