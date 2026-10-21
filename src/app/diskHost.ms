import { Clipboard } from "../../../neon/src/api/clipboard";
import { cwd, exit } from "std/process";
import { exists, readFile, rename, writeFile } from "std/fs";
import { dirname, join, normalize, resolve } from "std/fs/path";
import { Clip } from "../model/commands";
import { Link } from "../lsp/session";
import { filePath, fileUri } from "../lsp/uri";
import { FileText, Platform } from "./app";
import { EditorConfigFile } from "../model/editorconfig";
import { Document } from "../model/document";
import { Query } from "../model/find";
import { ProjectResults, searchProject } from "../model/projectSearch";
import { projectFiles } from "./files/projectFiles";

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

export function canonical(path: string): string {
	const full = normalize(resolve(path, cwd()));
	return full.byteLength >= 2 && full.byteAt(1) == ":".code ? full.byteSlice(0, 1).toUpperCase() + full.byteSlice(1, full.byteLength) : full;
}

export function projectRoot(file: string): string {
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

export function diskHost(root: string, link: ((command: string) => Link | null) | null, processId: int32 | null): Platform {
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
		search: (q: Query, openDoc: (key: string) => Document | null): ProjectResults => searchProject(
			projectFiles(root).map((shown: string): string => canonical(join(root, shown))),
			openDoc,
			(key: string): string | null => {
				const text = readFile(key);
				return text.ok ? text.value : null;
			},
			q,
		),
		editorConfigs,
		keyOf: (shown: string): string => canonical(join(root, shown)),
		keyOfUri: (uri: string): string | null => {
			const path = filePath(uri);
			return path === null ? null : canonical(path as string);
		},
		shown: (key: string): string => key.startsWith(under) ? key.byteSlice(under.byteLength, key.byteLength) : key,
		link,
		rootUri: fileUri(root),
		processId,
	};
}

