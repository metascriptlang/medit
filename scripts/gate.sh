#!/bin/sh
# The land gate of CLAUDE.md §Gate: every test file, then the desktop and both web builds.
set -e
cd "$(dirname "$0")/.."
for f in $(grep -rl '^test ' src); do
	msc test "$f" > out/gate-test.log 2>&1 || { grep -E "^ *(×|AssertionError|at )|error" out/gate-test.log | head -20; echo "gate: red in $f"; exit 1; }
	echo "gate: green $f"
done
msc build src/app/medic.ms --output=out/medic.exe > out/gate-desktop.log 2>&1 || { tail -20 out/gate-desktop.log; echo "gate: desktop build failed"; exit 1; }
echo "gate: desktop built"
sh scripts/buildWeb.sh gl wgpu > out/gate-web.log 2>&1 || { tail -20 out/gate-web.log; echo "gate: web build failed"; exit 1; }
echo "gate: web gl and wgpu built"
