import { NeonNode } from "../../../neon/src/render/node";
import { runWindow, DesktopOptions, desktopOptions } from "../../../neon/src/platform/ion/window";
import { argv, exit } from "std/process";
import { exists, isDir } from "std/fs";
import { Link } from "../lsp/session";
import { App } from "./app";
import { canonical, diskHost, projectRoot } from "./diskHost";
import { processLink } from "./lsp/processLink";
import { ownProcessId } from "./lsp/serverProcess";

const FONT_PATH = "assets/JetBrainsMonoNL-Regular.ttf";

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
	return runWindow(opts, (): NeonNode => App(diskHost(root, (command: string): Link | null => processLink(command, root), ownProcessId()), folder ? null : target)) as int32;
}

exit(main());
