import { execFileResult, findOnPath } from "std/process";
import { readDir } from "std/fs";

export const FILES_LIMIT: int32 = 200000;
const SKIPPED = [".git", "node_modules", "out", "target"];

function gitFiles(root: string): string[] | null {
	const git = findOnPath("git");
	if (git == "") { return null; }
	const run = execFileResult(git, ["ls-files", "-co", "--exclude-standard", "-z"], root);
	if (!run.started || !run.pipeOk || run.exitCode != 0) { return null; }
	const files: string[] = [];
	for (const path of run.output.split("\u0000")) {
		if ((files.length as int32) == FILES_LIMIT) { break; }
		if (path.byteLength > 0) { files.push(path); }
	}
	return files;
}

function walked(root: string): string[] {
	const files: string[] = [];
	const pending: string[] = [""];
	while (pending.length > 0 && (files.length as int32) < FILES_LIMIT) {
		const dir = pending.pop() as string;
		for (const entry of readDir(dir.byteLength == 0 ? root : `${root}/${dir}`)) {
			const isFolder = entry.endsWith("/");
			const name = isFolder ? entry.byteSlice(0, entry.byteLength - 1) : entry;
			const path = dir.byteLength == 0 ? name : `${dir}/${name}`;
			if (!isFolder) {
				if ((files.length as int32) < FILES_LIMIT) { files.push(path); }
			} else if (!SKIPPED.includes(name)) {
				pending.push(path);
			}
		}
	}
	files.sort();
	return files;
}

export function projectFiles(root: string): string[] {
	const listed = gitFiles(root);
	return listed === null ? walked(root) : listed as string[];
}

when (testBuild) {
	test "a git work tree lists its tracked and untracked files with slashes" {
		const files = projectFiles(".");
		assert files.includes("src/app/files/projectFiles.ms");
		assert !files.some((p: string): boolean => p.startsWith(".git/") || p.indexOf("\\") >= 0);
	}

	test "outside git, the walk lists files and skips build and vendor folders" {
		const files = walked(".");
		assert files.includes("src/app/files/projectFiles.ms");
		assert !files.some((p: string): boolean => p.startsWith(".git/") || p.startsWith("out/"));
	}
}
