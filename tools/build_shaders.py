import argparse
import glob
import os
import re
import shutil
import tempfile

from toolchain import ADDON, host_path, run_exe

ANSI = re.compile(r"\x1b\[[0-9;]*[mK]")
VENDOR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shadercompile")


def main():
    ap = argparse.ArgumentParser(description="Compile the impostor shaders into addon/shaders/fxc")
    ap.add_argument("--guide", default=os.environ.get("SHADERGUIDE", VENDOR),
        help="folder with ShaderCompile.exe and the Source shader headers (or SHADERGUIDE)")
    ap.add_argument("--d3dcompiler", default=os.environ.get("D3DCOMPILER"),
        help="a 64 bit d3dcompiler_47.dll, default the one next to ShaderCompile.exe (or D3DCOMPILER)")
    a = ap.parse_args()
    if not os.path.exists(os.path.join(a.guide, "ShaderCompile.exe")):
        ap.error("no ShaderCompile.exe in " + a.guide)

    with tempfile.TemporaryDirectory() as work:
        for f in glob.glob(os.path.join(a.guide, "*.h")) + [os.path.join(a.guide, "ShaderCompile.exe")]:
            shutil.copy(f, work)
        dll = a.d3dcompiler or os.path.join(a.guide, "d3dcompiler_47.dll")
        if os.path.exists(dll):
            shutil.copy(dll, os.path.join(work, "d3dcompiler_47.dll"))
        for f in glob.glob(os.path.join(ADDON, "shaders", "*.hlsl")):
            shutil.copy(f, work)

        for f in sorted(glob.glob(os.path.join(work, "*.hlsl"))):
            name = os.path.basename(f)
            version = "30" if re.search(r"(_vs30|_ps30|3x)\.hlsl$", name) else "20b"
            text = run_exe(os.path.join(work, "ShaderCompile.exe"),
                ["/O", "3", "-ver", version, "-shaderpath", host_path(work), "./" + name], cwd=work,
                env={"WINEDLLOVERRIDES": "d3dcompiler_47=n"})
            errors = [l for l in ANSI.sub("", text).splitlines() if re.search(r"error|FAILED|E\d{4}", l, re.I)]
            print(name, "ok" if not errors else "\n  " + "\n  ".join(errors))

        out = os.path.join(ADDON, "shaders", "fxc")
        os.makedirs(out, exist_ok=True)
        for f in glob.glob(os.path.join(work, "shaders", "fxc", "*.vcs")):
            shutil.copy(f, out)
            print("wrote", os.path.relpath(os.path.join(out, os.path.basename(f)), ADDON))


if __name__ == "__main__":
    main()
