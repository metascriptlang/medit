#!/bin/sh
# Builds src/app/medicWeb.ms for the browser with --os=emcc, mirroring
# ~/metascript/void/scripts/build-web.sh: pinned emscripten, Windows emcc shims, msc retried on the
# uncached async-emcc path.
#
#   sh scripts/buildWeb.sh [gl|wgpu ...]
#
# Writes out/web/{gl,wgpu}/medicWeb.{js,wasm,data} and out/web/index.html.
set -e

BACKENDS="${*:-gl wgpu}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOID="$(cd "${VOID_DIR:-$ROOT/../void}" && pwd)"
OUT="$ROOT/out/web"
EMSDK_DIR="${EMSDK_DIR:-$HOME/projects/emsdk}"
MSC="${MSC:-msc}"
EMSCRIPTEN_VERSION="$(cat "$VOID/.emscripten-version")"

mkdir -p "$OUT/obj" "$OUT/log"

case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	SHIM="$ROOT/out/emcc-shim"
	mkdir -p "$SHIM"
	[ -x "$SHIM/emcc.exe" ] || clang -O2 -D_CRT_SECURE_NO_WARNINGS -o "$SHIM/emcc.exe" "$VOID/scripts/emccShim.c"
	for tool in em++ emar emranlib; do cp "$SHIM/emcc.exe" "$SHIM/$tool.exe"; done
	VOID_EMSDK_ROOT="$EMSDK_DIR"
	VOID_EMSDK_PYTHON="$(ls -d "$EMSDK_DIR"/python/*/python.exe 2>/dev/null | head -1)"
	[ -x "$VOID_EMSDK_PYTHON" ] || { echo "no emsdk python under $EMSDK_DIR/python"; exit 1; }
	EM_CONFIG="$EMSDK_DIR/.emscripten"
	export VOID_EMSDK_ROOT VOID_EMSDK_PYTHON EM_CONFIG
	PATH="$SHIM:$PATH"
	export PATH
	;;
*)
	. "$EMSDK_DIR/emsdk_env.sh" >/dev/null 2>&1
	;;
esac
active="$(cat "$EMSDK_DIR/upstream/emscripten/emscripten-version.txt" 2>/dev/null | tr -d '"')"
if [ "$active" != "$EMSCRIPTEN_VERSION" ]; then
	echo "emscripten is $active, .emscripten-version pins $EMSCRIPTEN_VERSION"
	exit 1
fi

relativeTo() {
	base="$1"; target="$2"; up=""
	while [ "${target#"$base"/}" = "$target" ]; do
		[ "$base" = "/" ] && { echo "$target"; return; }
		base="$(dirname "$base")"; up="../$up"
	done
	echo "$up${target#"$base"/}"
}

cd "$ROOT"
VOID_FONT="$(relativeTo "$ROOT" "$VOID/assets/font.ttf")"
PRELOAD="--preload-file assets/JetBrainsMonoNL-Regular.ttf --preload-file $VOID_FONT@assets/font.ttf"

build() {
	dir="$1"; api="$2"
	rm -f "$OUT/obj/medicWeb.js" "$OUT/obj/medicWeb.wasm" "$OUT/obj/medicWeb.data"
	for i in 1 2 3 4; do
		"$MSC" build src/app/medicWeb.ms --os=emcc "-d:$api" --passL="$PRELOAD" \
			--output="$OUT/obj/medicWeb.js" >"$OUT/log/medicWeb.$dir.log" 2>&1 || true
		if grep -q "Built" "$OUT/log/medicWeb.$dir.log" && [ -f "$OUT/obj/medicWeb.wasm" ]; then
			mkdir -p "$OUT/$dir"
			cp "$OUT/obj/medicWeb.js" "$OUT/obj/medicWeb.wasm" "$OUT/obj/medicWeb.data" "$OUT/$dir/"
			echo "medicWeb $dir (attempt $i)"
			return 0
		fi
	done
	echo "medicWeb $dir FAILED after retries, see $OUT/log/medicWeb.$dir.log"
	return 1
}

for b in $BACKENDS; do
	case "$b" in
	gl) build gl webgl2 ;;
	wgpu) build wgpu webgpu ;;
	*) echo "unknown backend $b"; exit 1 ;;
	esac
done
cp "$ROOT/web/index.html" "$OUT/index.html"
