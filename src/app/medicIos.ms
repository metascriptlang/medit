import { NeonNode } from "../../../neon/src/render/node";
import { runCanvas, CanvasOptions, canvasOptions } from "../../../neon/src/platform/sokol/canvas";
import { join } from "std/fs/path";
import { homeDir } from "std/os";
import { exit } from "std/process";
import { resourcePath } from "../../../ion/src/window";
import { App } from "./app";
import { diskHost } from "./diskHost";

const FONT_PATH = join(resourcePath(), "assets/JetBrainsMonoNL-Regular.ttf");

const root = join(homeDir(), "Documents");
const opts: CanvasOptions = { ...canvasOptions(1024, 768), font: FONT_PATH };
exit(runCanvas(opts, (): NeonNode => App(diskHost(root, null, null), null)));
