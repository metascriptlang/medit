#!/bin/sh
# Copies tree-sitter's C runtime and the MetaScript grammar into vendor/, and the grammar's
# highlight query, without its comment lines, into src/syntax/highlights.ms.
#   sh scripts/vendorSyntax.sh [runtime dir] [grammar dir]
set -e
cd "$(dirname "$0")/.."
RUNTIME=${1:-$HOME/scoop/persist/rustup/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/tree-sitter-0.25.10}
GRAMMAR=${2:-$HOME/metascript/recompiler/tools/editor-plugin/metascript.nvim/tree-sitter}
LICENSE=${LICENSE:-$HOME/scoop/persist/rustup/.cargo/git/checkouts/tree-sitter-a21c02e4b1d6dd0c/43623ec/LICENSE}

rm -rf vendor/tree-sitter vendor/tree-sitter-metascript
mkdir -p vendor/tree-sitter vendor/tree-sitter-metascript
cp -r "$RUNTIME/src" "$RUNTIME/include" vendor/tree-sitter/
rm -rf vendor/tree-sitter/src/wasm
cp "$LICENSE" vendor/tree-sitter/LICENSE
cp -r "$GRAMMAR/src/parser.c" "$GRAMMAR/src/scanner.c" "$GRAMMAR/src/tree_sitter" vendor/tree-sitter-metascript/
{
	echo "tree-sitter $(sed -n 's/^version = "\(.*\)"/\1/p' "$RUNTIME/Cargo.toml" | head -1)"
	echo "tree-sitter-metascript, recompiler $(git -C "$GRAMMAR" rev-parse --short HEAD) (MIT)"
} > vendor/SOURCES

{
	printf 'export const HIGHLIGHTS = `'
	sed -e '/^[[:space:]]*;/d' -e 's/\\/\\\\/g' -e 's/`/\\`/g' -e 's/\$[{]/\\${/g' "$GRAMMAR/queries/highlights.scm"
	printf '`;\n'
} > src/syntax/highlights.ms
