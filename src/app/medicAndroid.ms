import { NeonNode } from "../../../neon/src/render/node";
import { runCanvas, canvasOptions } from "../../../neon/src/platform/sokol/canvas";
import { cwd } from "std/process";
import { readResource } from "../../../ion/src/window";
import { App } from "./app";
import { diskHost } from "./diskHost";

const mono = readResource("assets/JetBrainsMonoNL-Regular.ttf");
if (!mono.ok) { throw new Error(`medic: the bundled font did not load: ${mono.error}`); }

// voidRun returns at once on Android while the activity keeps running, so nothing may exit after it.
runCanvas(
	{ ...canvasOptions(1024, 768), font: "JetBrains Mono", fontBytes: mono.value },
	(): NeonNode => App(diskHost(cwd(), null, null), null),
);
