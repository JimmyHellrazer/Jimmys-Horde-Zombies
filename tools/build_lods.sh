#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RATIOS="${RATIOS:-0.5,0.22,0.1}"
GMOD="${GMOD:-$HOME/.local/share/Steam/steamapps/common/GarrysMod}"
CROWBAR="${CROWBAR:-$HOME/projects/tools/crowbar/CrowbarCommandLineDecomp.exe}"
WINE="${WINE:-$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton11-7-x86_64/files/bin/wine}"
export WINEPREFIX="${WINEPREFIX:-$HOME/projects/tools/proton-prefix/pfx}" WINEDEBUG=-all
WORK="${WORK:-${TMPDIR:-/tmp}/hordez_lods}"
MODELS="$ROOT/addon/models/hordez/citizens"
ORIG="$ROOT/tools/models_original"
w() { echo "Z:${1//\//\\}"; }

mkdir -p "$WORK/game" "$ORIG"
ln -sfn "$ROOT/addon/materials" "$WORK/game/materials"
python3 "$ROOT/tools/lod_materials.py" "$ROOT/addon/materials/models/bloocobalt/citizens"
printf '"GameInfo"\n{\n\tgame "lodbuild"\n\tFileSystem\n\t{\n\t\tSteamAppId 4000\n\t\tSearchPaths\n\t\t{\n\t\t\tgame |gameinfo_path|.\n\t\t}\n\t}\n}\n' > "$WORK/game/gameinfo.txt"

names=("$@")
if [ ${#names[@]} -eq 0 ]; then
	for f in "$MODELS"/*.mdl; do names+=("$(basename "$f" .mdl)"); done
fi

for n in "${names[@]}"; do
	if [ ! -f "$ORIG/$n.mdl" ]; then cp "$MODELS/$n".{mdl,vvd,phy,dx90.vtx} "$ORIG/"; fi
	d="$WORK/$n"
	rm -rf "$d"; mkdir -p "$d/src"
	cp "$ORIG/$n".{mdl,vvd,phy,dx90.vtx} "$d/src/"
	"$WINE" "$CROWBAR" -p "$(w "$d/src/$n.mdl")" -o "$(w "$d")" > "$d/decompile.log" 2>&1
	qc="$(ls "$d"/*.qc | head -1)"
	( cd "$d" && python3 "$ROOT/tools/lod_qc.py" "$qc" "hordez/citizens/$n.mdl" > smds.txt \
		&& blender -b --python "$ROOT/tools/lod_decimate.py" -- "$RATIOS" $(cat smds.txt) > decimate.log 2>&1 )
	rm -f "$WORK/game/models/hordez/citizens/$n".*
	( cd "$GMOD/bin" && "$WINE" studiomdl.exe -nop4 -game "$(w "$WORK/game")" "$(w "$qc")" > "$d/compile.log" 2>&1 ) || true
	out="$WORK/game/models/hordez/citizens/$n"
	if ! grep -q '^Completed' "$d/compile.log" || [ ! -f "$out.mdl" ]; then
		echo "FAILED $n (see $d/compile.log)"; continue
	fi
	cp "$out".{mdl,vvd,phy,dx90.vtx} "$MODELS/"
	echo "built $n: $(grep -c '^LOD' "$d/decimate.log") parts"
done
