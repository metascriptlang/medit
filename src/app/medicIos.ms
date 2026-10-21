// Parked: std/process fails the C build for iOS,
// ~/metascript/.inbox/compiler/2026-10-21-std-process-does-not-compile-for-ios.md

import { NeonNode } from "../../../neon/src/render/node";
import { runCanvas, CanvasOptions, canvasOptions } from "../../../neon/src/platform/sokol/canvas";
import { ensureDir } from "std/fs";
import { join } from "std/fs/path";
import { homeDir } from "std/os";
import { exit } from "std/process";
import { App } from "./app";
import { diskHost } from "./diskHost";

// Parked: the font is found by a path relative to the working directory, which is / on iOS,
// ~/metascript/.inbox/compiler/2026-10-21-bundle-resource-path.md
const FONT_PATH = "assets/JetBrainsMonoNL-Regular.ttf";

const root = join(homeDir(), "Documents");
ensureDir(root);
const opts: CanvasOptions = { ...canvasOptions(1024, 768), font: FONT_PATH };
exit(runCanvas(opts, (): NeonNode => App(diskHost(root, null, null), null)));
