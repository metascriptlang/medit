const LINE_COMMENTS: Array<[string, string[]]> = [
	["// ", [
		"ms", "cms", "jms", "ems", "wms", "rms", "ts", "tsx", "js", "jsx", "mjs",
		"c", "h", "cc", "cpp", "hpp", "rs", "go", "java", "kt", "swift", "zig", "cs", "dart",
	]],
	["# ", ["sh", "bash", "zsh", "py", "rb", "pl", "toml", "yaml", "yml", "nim", "ps1", "r"]],
	["-- ", ["lua", "sql", "hs"]],
];

export function lineCommentOf(path: string): string | null {
	const dot = path.lastIndexOf(".");
	if (dot < 0) { return null; }
	const type = path.slice(dot + 1);
	for (const [marker, types] of LINE_COMMENTS) {
		if (types.includes(type)) { return marker; }
	}
	return null;
}

test "a line comment marker follows the file type" {
	assert lineCommentOf("src/app.ms") == "// ";
	assert lineCommentOf("build.toml") == "# ";
	assert lineCommentOf("init.lua") == "-- ";
	assert lineCommentOf("notes.txt") === null;
	assert lineCommentOf("Makefile") === null;
}
