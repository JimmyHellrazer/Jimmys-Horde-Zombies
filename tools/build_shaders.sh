#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${SHADERGUIDE:?set SHADERGUIDE to the shaders/ folder of the shader guide}"
WINE="${WINE:-$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton11-7-x86_64/files/bin/wine}"
export WINEPREFIX="${WINEPREFIX:-$HOME/projects/tools/proton-prefix/pfx}" WINEDEBUG=-all WINEDLLOVERRIDES="d3dcompiler_47=n"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$SHADERGUIDE"/*.h "$SHADERGUIDE"/ShaderCompile.exe "$WORK/"
if [ -n "${D3DCOMPILER:-}" ]; then cp "$D3DCOMPILER" "$WORK/d3dcompiler_47.dll"
elif [ -f "$SHADERGUIDE/d3dcompiler_47.dll" ]; then cp "$SHADERGUIDE/d3dcompiler_47.dll" "$WORK/"; fi
cp "$ROOT"/addon/shaders/*.hlsl "$WORK/"
cd "$WORK"
WINWORK="Z:$(echo "$WORK" | tr / '\\')"
for f in *.hlsl; do
	ver=20b; case "$f" in *_vs30.hlsl|*_ps30.hlsl|*3x.hlsl) ver=30;; esac
	"$WINE" ShaderCompile.exe /O 3 -ver "$ver" -shaderpath "$WINWORK" "./$f" 2>&1 | sed -e 's/\x1b\[[0-9;]*[mK]//g' | grep -iE "error|FAILED|E[0-9]{4}" || true
done
mkdir -p "$ROOT/addon/shaders/fxc"
cp shaders/fxc/*.vcs "$ROOT/addon/shaders/fxc/"
ls -la "$ROOT/addon/shaders/fxc"
