import { NeonNode } from "../../../neon/src/render/node";
import { runCanvas, CanvasOptions, canvasOptions } from "../../../neon/src/platform/sokol/canvas";
import { exit } from "std/process";
import { Clip } from "../model/commands";
import { Link } from "../lsp/session";
import { App, Connect } from "./app";
import { SAMPLE } from "./sample";
import { queryParam, requestFile } from "./lsp/socketWeb";
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

function store(text: string): string | null {
	return `the web build has no file to save ${text.byteLength} bytes to`;
}

const SAMPLE_PATH = "sample.ms";
const SAMPLE_URI = "file:///medic/sample.ms";

interface Opened {
	text: string;
	path: string;
	store: (text: string) => string | null;
	connect: Connect | null;
}

function connectTo(url: string, uri: string, rootUri: string | null): Connect | null {
	if (url.byteLength == 0) { return null; }
	return {
		link: (command: string): Link | null => socketLink(url),
		uri,
		rootUri,
		processId: null,
	};
}

function storeThrough(base: string, path: string): (text: string) => string | null {
	return (text: string): string | null => {
		const reply = requestFile("PUT", base, path, text);
		return reply.status == 204 ? null : `saving ${path} through the bridge: ${reply.status} ${reply.text}`;
	};
}

function openThrough(lsp: string, path: string): Opened {
	if (lsp.byteLength == 0) { fail(`?file=${path} needs ?lsp=, the bridge that serves it`); }
	const base = `http${lsp.byteSlice(2, lsp.byteLength)}`;
	const reply = requestFile("GET", base, path, "");
	if (reply.status != 200) { fail(`opening ${path} through the bridge: ${reply.status} ${reply.text}`); }
	const parsed = JSON.parseValue(reply.text);
	if (!parsed.ok) { fail(`the bridge sent ${path} as no JSON: ${parsed.error}`); }
	const file = parsed.value;
	return {
		text: file.getDynamicField("text").asString(),
		path,
		store: storeThrough(base, path),
		connect: connectTo(lsp, file.getDynamicField("uri").asString(), file.getDynamicField("rootUri").asString()),
	};
}

const lsp = queryParam("lsp");
const file = queryParam("file");
const opened: Opened = file.byteLength > 0 ? openThrough(lsp, file)
	: { text: SAMPLE, path: SAMPLE_PATH, store, connect: connectTo(lsp, SAMPLE_URI, null) };
const opts: CanvasOptions = { ...canvasOptions(960, 640), font: FONT_PATH };
exit(runCanvas(opts, (): NeonNode => App(opened.text, opened.path, appClip, opened.store, fail, opened.connect)));
