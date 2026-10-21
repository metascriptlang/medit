import { NeonNode } from "../../../neon/src/render/node";
import { runCanvas, CanvasOptions, canvasOptions } from "../../../neon/src/platform/sokol/canvas";
import { exit } from "std/process";
import { Clip } from "../model/commands";
import { Link } from "../lsp/session";
import { filePath } from "../lsp/uri";
import { App, FileText, Platform } from "./app";
import { EditorConfigFile } from "../model/editorconfig";
import { SAMPLE } from "./sample";
import { Document } from "../model/document";
import { Query } from "../model/find";
import { ProjectResults, searchProject, withOpenFiles } from "../model/projectSearch";
import { queryParam, requestFile, requestFiles, requestSearch } from "./lsp/socketWeb";
import { socketLink } from "./lsp/socketLink";

const FONT_PATH = "assets/JetBrainsMonoNL-Regular.ttf";

function fail(message: string): never {
	console.log(`medic: ${message}`);
	exit(1);
}

let held = "";
const appClip: Clip = {
	write: (text: string): void => { held = text; },
	read: (done: (text: string) => void): void => { done(held); },
};

const SAMPLE_PATH = "sample.ms";
const SAMPLE_URI = "file:///medic/sample.ms";

function linkTo(url: string): ((command: string) => Link | null) | null {
	return url.byteLength == 0 ? null : (command: string): Link | null => socketLink(url);
}

function sampleHost(lsp: string): Platform {
	return {
		clip: appClip,
		fail,
		read: (key: string): FileText => key == SAMPLE_PATH ? { text: SAMPLE, uri: SAMPLE_URI, error: null }
			: { text: "", uri: "", error: `the web build has no file ${key}: start the bridge with --root` },
		store: (key: string, text: string): string | null => `the web build has no file to save ${text.byteLength} bytes to`,
		files: (): string[] => [],
		search: (q: Query, openDoc: (key: string) => Document | null): ProjectResults => searchProject(
			[SAMPLE_PATH],
			openDoc,
			(key: string): string | null => key == SAMPLE_PATH ? SAMPLE : null,
			q,
		),
		editorConfigs: (key: string): EditorConfigFile[] => [],
		keyOf: (shown: string): string => shown,
		keyOfUri: (uri: string): string | null => uri == SAMPLE_URI ? SAMPLE_PATH : null,
		shown: (key: string): string => key,
		link: linkTo(lsp),
		rootUri: null,
		processId: null,
	};
}

interface Listing {
	rootUri: string;
	files: string[];
}

function listThrough(base: string): Listing | null {
	const reply = requestFiles(base);
	if (reply.status != 200) {
		console.log(`medic: listing the project through the bridge: ${reply.status} ${reply.text}`);
		return null;
	}
	const parsed = JSON.parseValue(reply.text);
	if (!parsed.ok) {
		console.log(`medic: the bridge sent the project's files as no JSON: ${parsed.error}`);
		return null;
	}
	const listed = parsed.value.getDynamicField("files");
	const files: string[] = [];
	for (let i = 0; i < (listed.length() as int32); i++) { files.push(listed.at(i).asString()); }
	return { rootUri: parsed.value.getDynamicField("rootUri").asString(), files };
}

function under(path: string, dir: string): string | null {
	const at = dir.byteLength;
	if (path.byteLength <= at || path.byteAt(at) != "/".code) { return null; }
	if (path.byteSlice(0, 1).toLowerCase() != dir.byteSlice(0, 1).toLowerCase() || path.byteSlice(1, at) != dir.byteSlice(1, at)) { return null; }
	return path.byteSlice(at + 1, path.byteLength);
}

function editorConfigsThrough(base: string, key: string): EditorConfigFile[] {
	const found: EditorConfigFile[] = [];
	let dir = "";
	let at = 0;
	while (at >= 0) {
		const reply = requestFile("GET", base, dir == "" ? ".editorconfig" : `${dir}/.editorconfig`, "");
		if (reply.status == 200) {
			const parsed = JSON.parseValue(reply.text);
			if (parsed.ok) { found.push({ dir, text: parsed.value.getDynamicField("text").asString() }); }
		}
		at = key.byteIndexOf("/", dir == "" ? 0 : dir.byteLength + 1);
		if (at >= 0) { dir = key.byteSlice(0, at); }
	}
	return found;
}

const NOTHING_FOUND: ProjectResults = { files: [], matches: 0, limitReached: false };

function searchThrough(base: string, q: Query): ProjectResults {
	const reply = requestSearch(base, q.text, q.caseSensitive, q.wholeWord);
	if (reply.status != 200) {
		console.log(`medic: searching through the bridge: ${reply.status} ${reply.text}`);
		return NOTHING_FOUND;
	}
	const parsed = JSON.parse<ProjectResults>(reply.text);
	if (!parsed.ok) {
		console.log(`medic: the bridge sent search results as no JSON: ${parsed.error}`);
		return NOTHING_FOUND;
	}
	return parsed.value;
}

function bridgeHost(lsp: string, base: string, rootUri: string): Platform {
	const rootPath = filePath(rootUri) as string;
	const dir = rootPath.endsWith("/") ? rootPath.byteSlice(0, rootPath.byteLength - 1) : rootPath;
	return {
		clip: appClip,
		fail,
		read: (key: string): FileText => {
			const reply = requestFile("GET", base, key, "");
			if (reply.status != 200) { return { text: "", uri: "", error: `opening ${key} through the bridge: ${reply.status} ${reply.text}` }; }
			const parsed = JSON.parseValue(reply.text);
			if (!parsed.ok) { return { text: "", uri: "", error: `the bridge sent ${key} as no JSON: ${parsed.error}` }; }
			return { text: parsed.value.getDynamicField("text").asString(), uri: parsed.value.getDynamicField("uri").asString(), error: null };
		},
		store: (key: string, text: string): string | null => {
			const reply = requestFile("PUT", base, key, text);
			return reply.status == 204 ? null : `saving ${key} through the bridge: ${reply.status} ${reply.text}`;
		},
		files: (): string[] => {
			const listing = listThrough(base);
			return listing === null ? [] : (listing as Listing).files;
		},
		search: (q: Query, openDoc: (key: string) => Document | null): ProjectResults => {
			const listing = listThrough(base);
			return withOpenFiles(searchThrough(base, q), listing === null ? [] : (listing as Listing).files, openDoc, q);
		},
		editorConfigs: (key: string): EditorConfigFile[] => editorConfigsThrough(base, key),
		keyOf: (shown: string): string => shown,
		keyOfUri: (uri: string): string | null => {
			const path = filePath(uri);
			return path === null ? null : under(path as string, dir);
		},
		shown: (key: string): string => key,
		link: linkTo(lsp),
		rootUri,
		processId: null,
	};
}

const lsp = queryParam("lsp");
const file = queryParam("file");
const base = lsp.byteLength == 0 ? "" : `http${lsp.byteSlice(2, lsp.byteLength)}`;
const listing = base.byteLength == 0 ? null : listThrough(base);
if (file.byteLength > 0 && listing === null) { fail(`?file=${file} needs ?lsp=, a bridge started with --root`); }
const platform: Platform = listing === null ? sampleHost(lsp) : bridgeHost(lsp, base, (listing as Listing).rootUri);
const first: string | null = listing === null ? SAMPLE_PATH : file.byteLength > 0 ? file : null;
const opts: CanvasOptions = { ...canvasOptions(960, 640), font: FONT_PATH };
exit(runCanvas(opts, (): NeonNode => App(platform, first)));
