import { NeonNode } from "../../../neon/src/render/node";
import { runWindow, DesktopOptions, desktopOptions } from "../../../neon/src/platform/ion/window";
import { Clipboard } from "../../../neon/src/api/clipboard";
import { argv, exit } from "std/process";
import { readFile, rename, writeFile } from "std/fs";
import { Clip } from "../model/commands";
import { App } from "./app";

const FONT_PATH = "assets/JetBrainsMonoNL-Regular.ttf";

function fail(message: string): void {
	console.log(`medic: ${message}`);
	exit(1);
}

const systemClip: Clip = {
	write: (text: string): void => {
		try {
			Clipboard.setString(text);
		} catch (e) {
			console.log(`medic: copy failed: ${e}`);
		}
	},
	read: (done: (text: string) => void): void => {
		Clipboard.getString().then((text: string): void => { done(text); });
	},
};

function storeTo(path: string): (text: string) => void {
	return (text: string): void => {
		const temp = `${path}.medic-save`;
		const wrote = writeFile(temp, text);
		if (!wrote.ok) {
			console.log(`medic: cannot save ${path}: ${wrote.error.toString()}`);
			return;
		}
		const moved = rename(temp, path);
		if (!moved.ok) { console.log(`medic: saved to ${temp}, but cannot replace ${path}: ${moved.error.toString()}`); }
	};
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
	const contents = text.value;
	const opts: DesktopOptions = { ...desktopOptions(`medic ${path}`, 960, 640), font: FONT_PATH };
	return runWindow(opts, (): NeonNode => App(contents, path, systemClip, storeTo(path), fail)) as int32;
}

exit(main());
