import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile

from toolchain import ADDON, WINDOWS, find_game, find_program, host_path, run_exe, write_gameinfo

HERE = os.path.dirname(os.path.abspath(__file__))
MODELS = os.path.join(ADDON, "models", "hordez", "citizens")
ORIGINALS = os.path.join(HERE, "models_original")
PARTS = (".mdl", ".vvd", ".phy", ".dx90.vtx")


def main():
    ap = argparse.ArgumentParser(description="Rebuild the zombie models with baked faces, LODs and LOD materials")
    ap.add_argument("names", nargs="*", help="model names, default all")
    ap.add_argument("--gmod", help="GarrysMod folder (or GMOD)")
    ap.add_argument("--crowbar", help="CrowbarCommandLineDecomp.exe (or CROWBAR)")
    ap.add_argument("--blender", help="blender executable (or BLENDER)")
    ap.add_argument("--work", default=os.path.join(tempfile.gettempdir(), "hordez_lods"))
    ap.add_argument("--ratios", default="0.5,0.22,0.1", help="triangle ratio per LOD")
    a = ap.parse_args()

    gmod = find_game("GarrysMod", a.gmod, "GMOD")
    crowbar = find_program(a.crowbar, "CROWBAR", ["CrowbarCommandLineDecomp.exe", "CrowbarCommandLineDecomp"])
    blender = find_program(a.blender, "BLENDER", ["blender"],
        [r"C:\Program Files\Blender Foundation\Blender*\blender.exe"] if WINDOWS else [])
    studiomdl = os.path.join(gmod, "bin", "studiomdl.exe")
    game = os.path.join(a.work, "game")
    write_gameinfo(game)
    materials = os.path.join(game, "materials", "models", "bloocobalt")
    shutil.rmtree(materials, ignore_errors=True)
    os.makedirs(ORIGINALS, exist_ok=True)
    subprocess.run([sys.executable, os.path.join(HERE, "lod_materials.py"),
        os.path.join(ADDON, "materials", "models", "bloocobalt", "citizens")], check=True)
    shutil.copytree(os.path.join(ADDON, "materials", "models", "bloocobalt"), materials,
        ignore=shutil.ignore_patterns("*.vtf"))

    names = a.names or sorted(os.path.basename(p)[:-4] for p in glob.glob(os.path.join(MODELS, "*.mdl")))
    failed = []
    for name in names:
        for ext in PARTS:
            if not os.path.exists(os.path.join(ORIGINALS, name + ext)):
                shutil.copy(os.path.join(MODELS, name + ext), ORIGINALS)
        work = os.path.join(a.work, name)
        shutil.rmtree(work, ignore_errors=True)
        os.makedirs(os.path.join(work, "src"))
        for ext in PARTS:
            shutil.copy(os.path.join(ORIGINALS, name + ext), os.path.join(work, "src"))

        run_exe(crowbar, ["-p", host_path(os.path.join(work, "src", name + ".mdl")), "-o", host_path(work)],
            log=os.path.join(work, "decompile.log"))
        qcs = glob.glob(os.path.join(work, "*.qc"))
        if not qcs:
            failed.append(f"{name}: decompile")
            continue

        qc = qcs[0]
        steps = [[sys.executable, os.path.join(HERE, "bake_face.py"), qc],
            [sys.executable, os.path.join(HERE, "lod_qc.py"), qc, f"hordez/citizens/{name}.mdl"]]
        outputs = [subprocess.run(s, cwd=work, capture_output=True, text=True, check=True).stdout for s in steps]
        smds = outputs[1].split()
        decimate = subprocess.run([blender, "-b", "--python", os.path.join(HERE, "lod_decimate.py"), "--", a.ratios]
            + smds, cwd=work, capture_output=True, text=True)
        open(os.path.join(work, "decimate.log"), "w").write(decimate.stdout + decimate.stderr)

        built = os.path.join(game, "models", "hordez", "citizens", name)
        for ext in PARTS:
            if os.path.exists(built + ext):
                os.remove(built + ext)
        log = run_exe(studiomdl, ["-nop4", "-game", host_path(game), host_path(qc)], cwd=os.path.join(gmod, "bin"),
            log=os.path.join(work, "compile.log"))
        if "Completed" not in log or not os.path.exists(built + ".mdl"):
            failed.append(f"{name}: compile, see {os.path.join(work, 'compile.log')}")
            continue

        for ext in PARTS:
            shutil.copy(built + ext, MODELS)
        print(f"built {name} ({outputs[0].strip()})")

    print("failed:", "; ".join(failed) if failed else "none")


if __name__ == "__main__":
    main()
