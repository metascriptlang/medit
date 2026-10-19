import { NeonNode } from "../../../neon/src/render/node";
import { runCanvas, CanvasOptions, canvasOptions } from "../../../neon/src/platform/sokol/canvas";
import { exit } from "std/process";
import { App, linesOf } from "./app";
import { SAMPLE } from "./sample";

const FONT_PATH = "assets/JetBrainsMonoNL-Regular.ttf";

function fail(message: string): void {
	console.log(`medic: ${message}`);
	exit(1);
}

const lines = linesOf(SAMPLE);
const opts: CanvasOptions = { ...canvasOptions(960, 640), font: FONT_PATH };
exit(runCanvas(opts, (): NeonNode => App(lines, fail)));
