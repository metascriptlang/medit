const LINE_COMMENTS: Array<[string, string[]]> = [
	["// ", [
		"ms", "cms", "jms", "ems", "wms", "rms", "ts", "tsx", "js", "jsx", "mjs",
		"c", "h", "cc", "cpp", "hpp", "rs", "go", "java", "kt", "swift", "zig", "cs", "dart",
	]],
	["# ", ["sh", "bash", "zsh", "py", "rb", "pl", "toml", "yaml", "yml", "nim", "ps1", "r"]],
	["-- ", ["lua", "sql", "hs"]],
];

export struct BlockComment {
	open: string;
	close: string;
}

const BLOCK_COMMENTS: Array<[BlockComment, string[]]> = [
	[{ open: "/* ", close: " */" }, [
		"ms", "cms", "jms", "ems", "wms", "rms", "ts", "tsx", "js", "jsx", "mjs",
		"c", "h", "cc", "cpp", "hpp", "rs", "go", "java", "kt", "swift", "cs", "dart", "css", "sql",
	]],
	[{ open: "<!-- ", close: " -->" }, ["html", "xml"]],
	[{ open: "--[[ ", close: " ]]" }, ["lua"]],
	[{ open: "{- ", close: " -}" }, ["hs"]],
];

export struct DocComment {
	open: string;
	prefix: string;
	close: string;
}

const DOC_COMMENTS: Array<[DocComment, string[]]> = [
	[{ open: "/**", prefix: "* ", close: "*/" }, ["ms", "cms", "jms", "ems", "wms", "rms", "ts", "tsx", "js", "jsx", "mjs"]],
	[{ open: "/*", prefix: "* ", close: "*/" }, ["c", "h", "cc", "cpp", "hpp", "rs", "go"]],
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

export function blockCommentOf(path: string): BlockComment | null {
	const type = typeOf(path);
	if (type === null) { return null; }
	for (const [markers, types] of BLOCK_COMMENTS) {
		if (types.includes(type as string)) { return markers; }
	}
	return null;
}

export function docCommentOf(path: string): DocComment | null {
	const type = typeOf(path);
	if (type === null) { return null; }
	for (const [shape, types] of DOC_COMMENTS) {
		if (types.includes(type as string)) { return shape; }
	}
	return null;
}

test "a doc comment opens with two stars in script types, one in C-like types, and some types have none" {
	const ts = docCommentOf("a/b.ts");
	assert ts !== null && ts.open == "/**" && ts.prefix == "* " && ts.close == "*/";
	const rs = docCommentOf("lib.rs");
	assert rs !== null && rs.open == "/*";
	assert docCommentOf("run.py") === null;
	assert docCommentOf("Makefile") === null;
}

test "block comment markers follow the file type, and some types have none" {
	const ms = blockCommentOf("src/app.ms");
	assert ms !== null && ms.open == "/* " && ms.close == " */";
	const lua = blockCommentOf("init.lua");
	assert lua !== null && lua.open == "--[[ ";
	assert blockCommentOf("main.zig") === null;
	assert blockCommentOf("run.py") === null;
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
