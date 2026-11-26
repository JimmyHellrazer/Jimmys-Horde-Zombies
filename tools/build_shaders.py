import argparse
import glob
import lzma
import os
import re
import shutil
import struct
import subprocess
import tempfile

from toolchain import ADDON, find_program, host_path, run_exe

ANSI = re.compile(r"\x1b\[[0-9;]*[mK]")
VENDOR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shadercompile")
DX12 = re.compile(r"_(vs|ps)64\.hlsl$")
LZMA_DICT = 1 << 16
LZMA_PROPS = (2 * 5 + 0) * 9 + 3


def lzma_block(payload):
    packed = lzma.compress(payload, format=lzma.FORMAT_RAW,
        filters=[{"id": lzma.FILTER_LZMA1, "dict_size": LZMA_DICT, "lc": 3, "lp": 0, "pb": 2}])
    return b"LZMA" + struct.pack("<II", len(payload), len(packed)) + struct.pack("<BI", LZMA_PROPS, LZMA_DICT) + packed


def write_vcs(path, bytecode):
    block = lzma_block(struct.pack("<II", 0, len(bytecode)) + bytecode)
    start = 28 + 16 + 4
    end = start + 4 + len(block) + 4
    with open(path, "wb") as f:
        f.write(struct.pack("<7i", 6, 1, 1, 0, 0, 2, 0))
        f.write(struct.pack("<IIII", 0, start, 0xFFFFFFFF, end))
        f.write(struct.pack("<I", 0))
        f.write(struct.pack("<I", 0x40000000 | len(block)) + block + struct.pack("<I", 0xFFFFFFFF))


def build_dx9(a, sources):
    if not os.path.exists(os.path.join(a.guide, "ShaderCompile.exe")):
        print("skipping dx9 shaders, no ShaderCompile.exe in " + a.guide)
        return

    with tempfile.TemporaryDirectory() as work:
        for f in glob.glob(os.path.join(a.guide, "*.h")) + [os.path.join(a.guide, "ShaderCompile.exe")]:
            shutil.copy(f, work)
        dll = a.d3dcompiler or os.path.join(a.guide, "d3dcompiler_47.dll")
        if os.path.exists(dll):
            shutil.copy(dll, os.path.join(work, "d3dcompiler_47.dll"))
        for f in sources:
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


def build_dx12(a, sources):
    if not sources:
        return

    dxc = find_program(a.dxc, "DXC", ["dxc"])
    out = os.path.join(ADDON, "shaders", "dxc")
    os.makedirs(out, exist_ok=True)
    with tempfile.TemporaryDirectory() as work:
        for f in sorted(sources):
            name = os.path.basename(f)[:-len(".hlsl")]
            stage = DX12.search(f).group(1)
            compiled = os.path.join(work, name + ".dxil")
            result = subprocess.run([dxc, "-T", stage + "_6_4", "-E", "main", "-O3", "-Qstrip_reflect", "-Qstrip_debug",
                "-Fo", compiled, f],
                capture_output=True, text=True)
            if result.returncode != 0:
                print(name, "\n  " + "\n  ".join(result.stderr.strip().splitlines()))
                continue

            target = os.path.join(out, name + ".vcs")
            with open(compiled, "rb") as code:
                write_vcs(target, code.read())
            print(name, "ok, wrote", os.path.relpath(target, ADDON))


def main():
    ap = argparse.ArgumentParser(description="Compile the impostor shaders into addon/shaders/fxc and addon/shaders/dxc")
    ap.add_argument("--guide", default=os.environ.get("SHADERGUIDE", VENDOR),
        help="folder with ShaderCompile.exe and the Source shader headers (or SHADERGUIDE)")
    ap.add_argument("--d3dcompiler", default=os.environ.get("D3DCOMPILER"),
        help="a 64 bit d3dcompiler_47.dll, default the one next to ShaderCompile.exe (or D3DCOMPILER)")
    ap.add_argument("--dxc", default=os.environ.get("DXC"),
        help="Microsoft dxc for the DX12 shaders, default dxc on PATH (or DXC)")
    ap.add_argument("--only", choices=["dx9", "dx12"], help="build one set")
    a = ap.parse_args()

    sources = glob.glob(os.path.join(ADDON, "shaders", "*.hlsl"))
    if a.only != "dx12":
        build_dx9(a, [f for f in sources if not DX12.search(f)])
    if a.only != "dx9":
        build_dx12(a, [f for f in sources if DX12.search(f)])


if __name__ == "__main__":
    main()
