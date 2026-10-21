const LINE_COMMENTS: Array<[string, string[]]> = [
	["// ", [
		"ms", "cms", "jms", "ems", "wms", "rms", "ts", "tsx", "js", "jsx", "mjs",
		"c", "h", "cc", "cpp", "hpp", "rs", "go", "java", "kt", "swift", "zig", "cs", "dart",
	]],
	["# ", ["sh", "bash", "zsh", "py", "rb", "pl", "toml", "yaml", "yml", "nim", "ps1", "r"]],
	["-- ", ["lua", "sql", "hs"]],
];

export struct Language {
	id: string;
	server: string;
}

const LANGUAGES: Array<[Language, string[]]> = [
	[{ id: "metascript", server: "msc lsp" }, ["ms", "cms", "jms", "ems", "wms", "rms"]],
	[{ id: "typescript", server: "typescript-language-server --stdio" }, ["ts", "mts", "cts"]],
	[{ id: "typescriptreact", server: "typescript-language-server --stdio" }, ["tsx"]],
	[{ id: "javascript", server: "typescript-language-server --stdio" }, ["js", "mjs", "cjs"]],
	[{ id: "javascriptreact", server: "typescript-language-server --stdio" }, ["jsx"]],
	[{ id: "rust", server: "rust-analyzer" }, ["rs"]],
	[{ id: "c", server: "clangd" }, ["c", "h"]],
	[{ id: "cpp", server: "clangd" }, ["cc", "cpp", "cxx", "hpp", "hh"]],
	[{ id: "go", server: "gopls" }, ["go"]],
	[{ id: "python", server: "pyright-langserver --stdio" }, ["py"]],
	[{ id: "zig", server: "zls" }, ["zig"]],
	[{ id: "lua", server: "lua-language-server" }, ["lua"]],
];

function typeOf(path: string): string | null {
	const dot = path.lastIndexOf(".");
	const slash = Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
	return dot < 0 || dot < slash ? null : path.slice(dot + 1);
}

export function languageOf(path: string): Language | null {
	const type = typeOf(path);
	if (type === null) { return null; }
	for (const [language, types] of LANGUAGES) {
		if (types.includes(type as string)) { return language; }
	}
	return null;
}

export function lineCommentOf(path: string): string | null {
	const type = typeOf(path);
	if (type === null) { return null; }
	for (const [marker, types] of LINE_COMMENTS) {
		if (types.includes(type as string)) { return marker; }
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

test "a language and its server follow the file type" {
	const ms = languageOf("C:/w/src/app.ms");
	assert ms !== null && ms.id == "metascript" && ms.server == "msc lsp";
	const tsx = languageOf("view.tsx");
	assert tsx !== null && tsx.id == "typescriptreact";
	assert languageOf("notes.txt") === null;
	assert languageOf("v1.2/Makefile") === null;
	assert languageOf("C:\\v1.2\\Makefile") === null;
}
