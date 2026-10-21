import { NeonNode } from "../../../neon/src/render/node";
import { runCanvas, CanvasOptions, canvasOptions } from "../../../neon/src/platform/sokol/canvas";
import { exit } from "std/process";
import { Clip } from "../model/commands";
import { Link } from "../lsp/session";
import { App, Connect } from "./app";
import { SAMPLE } from "./sample";
import { queryParam } from "./lsp/socketWeb";
import { socketLink } from "./lsp/socketLink";

const FONT_PATH = "assets/JetBrainsMonoNL-Regular.ttf";

function fail(message: string): void {
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

function connectTo(url: string): Connect | null {
	if (url.byteLength == 0) { return null; }
	return {
		link: (command: string): Link | null => socketLink(url),
		uri: SAMPLE_URI,
		rootUri: null,
		processId: null,
	};
}

const opts: CanvasOptions = { ...canvasOptions(960, 640), font: FONT_PATH };
exit(runCanvas(opts, (): NeonNode => App(SAMPLE, SAMPLE_PATH, appClip, store, fail, connectTo(queryParam("lsp")))));
