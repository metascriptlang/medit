import { NeonNode } from "../../../neon/src/render/node";
import { runWindow, DesktopOptions, desktopOptions } from "../../../neon/src/platform/ion/window";
import { Clipboard } from "../../../neon/src/api/clipboard";
import { argv, cwd, exit } from "std/process";
import { exists, isDir, readFile, rename, writeFile } from "std/fs";
import { dirname, join, normalize, resolve } from "std/fs/path";
import { Clip } from "../model/commands";
import { Link } from "../lsp/session";
import { filePath, fileUri } from "../lsp/uri";
import { App, FileText, Platform } from "./app";
import { EditorConfigFile } from "../model/editorconfig";
import { projectFiles } from "./files/projectFiles";
import { processLink } from "./lsp/processLink";
import { ownProcessId } from "./lsp/serverProcess";

const FONT_PATH = "assets/JetBrainsMonoNL-Regular.ttf";
const ROOT_MARKER = ".git";

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

function store(path: string, text: string): string | null {
	const temp = `${path}.medic-save`;
	const wrote = writeFile(temp, text);
	if (!wrote.ok) { return `cannot save: ${wrote.error.toString()}`; }
	const moved = rename(temp, path);
	if (!moved.ok) { return `saved to ${temp}, but cannot replace the file: ${moved.error.toString()}`; }
	return null;
}

function canonical(path: string): string {
	const full = normalize(resolve(path, cwd()));
	return full.byteLength >= 2 && full.byteAt(1) == ":".code ? full.byteSlice(0, 1).toUpperCase() + full.byteSlice(1, full.byteLength) : full;
}

function projectRoot(file: string): string {
	let dir = dirname(file);
	while (!exists(join(dir, ROOT_MARKER))) {
		const up = dirname(dir);
		if (up == dir) { return dirname(file); }
		dir = up;
	}
	return dir;
}

function editorConfigs(path: string): EditorConfigFile[] {
	const found: EditorConfigFile[] = [];
	let dir = dirname(path);
	while (true) {
		const text = readFile(join(dir, ".editorconfig"));
		if (text.ok) { found.push({ dir, text: text.value }); }
		const up = dirname(dir);
		if (up == dir) {
			found.reverse();
			return found;
		}
		dir = up;
	}
}

function hostFor(root: string): Platform {
	const under = root.endsWith("/") ? root : `${root}/`;
	return {
		clip: systemClip,
		fail,
		read: (key: string): FileText => {
			const text = readFile(key);
			return text.ok ? { text: text.value, uri: fileUri(key), error: null }
				: { text: "", uri: "", error: `cannot read ${key}: ${text.error.toString()}` };
		},
		store,
		files: (): string[] => projectFiles(root),
		editorConfigs,
		keyOf: (shown: string): string => canonical(join(root, shown)),
		keyOfUri: (uri: string): string | null => {
			const path = filePath(uri);
			return path === null ? null : canonical(path as string);
		},
		shown: (key: string): string => key.startsWith(under) ? key.byteSlice(under.byteLength, key.byteLength) : key,
		link: (command: string): Link | null => processLink(command, root),
		rootUri: fileUri(root),
		processId: ownProcessId(),
	};
}

function main(): int32 {
	if (argv.length < 2) {
		console.log("usage: medic <file or folder>");
		return 2;
	}
	const path = argv[argv.length - 1];
	if (!exists(path)) {
		console.log(`medic: no file or folder at ${path}`);
		return 1;
	}
	const target = canonical(path);
	const folder = isDir(target);
	const root = folder ? target : canonical(projectRoot(target));
	// Parked: the title shows no unsaved marker until neon lets an app set its window title,
	// ~/metascript/.inbox/neon/2026-10-16-haro-window-title-from-an-app.md
	const opts: DesktopOptions = { ...desktopOptions(`medic ${path}`, 960, 640), font: FONT_PATH };
	return runWindow(opts, (): NeonNode => App(hostFor(root), folder ? null : target)) as int32;
}

exit(main());
