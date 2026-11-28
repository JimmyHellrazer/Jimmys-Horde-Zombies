import argparse
import os
import struct
import subprocess

from PIL import Image

from toolchain import ADDON, find_program

RAW = {0: ("RGBA", "RGBA", 4), 1: ("RGBA", "ABGR", 4), 2: ("RGB", "RGB", 3), 3: ("RGB", "BGR", 3),
    12: ("RGBA", "BGRA", 4), 16: ("RGB", "BGRX", 4)}
BLOCK = {13: 8, 14: 16, 15: 16, 20: 8}
DXT1, DXT5 = 13, 15
ENVMAP, ALPHA = 0x4000, 0x3000


def mip_bytes(fmt, w, h):
    if fmt in BLOCK:
        return max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * BLOCK[fmt]
    return w * h * RAW[fmt][2]


def read(path):
    data = open(path, "rb").read()
    if len(data) < 64 or data[:4] != b"VTF\0":
        return None
    major, minor, head = struct.unpack_from("<3I", data, 4)
    w, h, flags, frames = struct.unpack_from("<HHIH", data, 16)
    fmt, mips, low_fmt, low_w, low_h = struct.unpack_from("<iBiBB", data, 52)
    depth = struct.unpack_from("<H", data, 63)[0] if minor >= 2 else 1
    if major != 7 or minor > 2 or frames != 1 or depth > 1 or flags & ENVMAP or (fmt not in RAW and fmt not in BLOCK):
        return None
    if low_fmt not in (-1, DXT1):
        return None
    low = mip_bytes(DXT1, low_w, low_h) if low_fmt == DXT1 else 0
    sizes = [mip_bytes(fmt, max(1, w >> i), max(1, h >> i)) for i in range(mips)]
    if head + low + sum(sizes) != len(data):
        return None
    return dict(data=data, head=head, low=low, w=w, h=h, flags=flags, fmt=fmt, mips=mips, sizes=sizes)


def encode(magick, im, fmt):
    w, h = max(4, im.width), max(4, im.height)
    if (w, h) != im.size:
        im = im.resize((w, h), Image.NEAREST)
    im = im.convert("RGBA" if fmt == DXT5 else "RGB")
    out = subprocess.run([magick, "-size", f"{w}x{h}", "-depth", "8", ("rgba" if fmt == DXT5 else "rgb") + ":-",
        "-define", "dds:compression=" + ("dxt5" if fmt == DXT5 else "dxt1"), "-define", "dds:mipmaps=0",
        "-define", "dds:cluster-fit=true", "dds:-"], input=im.tobytes(), stdout=subprocess.PIPE, check=True).stdout
    blocks = out[128:]
    if out[:4] != b"DDS " or len(blocks) != mip_bytes(fmt, w, h):
        raise SystemExit("unexpected DDS output from " + magick)
    return blocks


def shrink(path, max_size, min_size, magick):
    tex = read(path)
    if not tex:
        return None
    data, w, h, fmt, mips, flags = tex["data"], tex["w"], tex["h"], tex["fmt"], tex["mips"], tex["flags"]
    start = tex["head"] + tex["low"]
    drop = 0
    while max(w, h) >> drop > max_size and drop < mips - 1:
        drop += 1

    sizes = tex["sizes"][drop:]
    w, h, mips = max(1, w >> drop), max(1, h >> drop), mips - drop
    body = data[start:start + sum(sizes)]
    if fmt in RAW and min(w, h) >= min_size:
        mode, raw, _ = RAW[fmt]
        levels, at = [], 0
        for i in reversed(range(mips)):
            size = (max(1, w >> i), max(1, h >> i))
            levels.append(Image.frombytes(mode, size, body[at:at + sizes[i]], "raw", raw))
            at += sizes[i]
        alpha = mode == "RGBA" and levels[-1].getchannel("A").getextrema() != (255, 255)
        fmt = DXT5 if alpha else DXT1
        if not alpha:
            flags &= ~ALPHA
        body = b"".join(encode(magick, im, fmt) for im in levels)
    elif not drop:
        return None

    head = bytearray(data[:start])
    struct.pack_into("<HHI", head, 16, w, h, flags)
    struct.pack_into("<iB", head, 52, fmt, mips)
    open(path, "wb").write(bytes(head) + body)
    return len(data), len(head) + len(body)


def main():
    ap = argparse.ArgumentParser(description="Cap texture size and compress uncompressed textures to DXT")
    ap.add_argument("root", nargs="?", default=os.path.join(ADDON, "materials"), help="materials folder")
    ap.add_argument("--max", type=int, default=1024, help="largest side kept")
    ap.add_argument("--min", type=int, default=512, help="smallest side that gets compressed")
    ap.add_argument("--magick", help="ImageMagick executable (or MAGICK)")
    a = ap.parse_args()

    magick = find_program(a.magick, "MAGICK", ["magick"])
    before = after = 0
    for folder, _, files in sorted(os.walk(a.root)):
        for name in sorted(files):
            if not name.lower().endswith(".vtf"):
                continue
            path = os.path.join(folder, name)
            result = shrink(path, a.max, a.min, magick)
            size = os.path.getsize(path)
            before += result[0] if result else size
            after += size
            if result:
                print("%s: %.2f -> %.2f MB" % (os.path.relpath(path, a.root), result[0] / 1e6, result[1] / 1e6), flush=True)

    print("total: %.1f -> %.1f MB" % (before / 1e6, after / 1e6))


if __name__ == "__main__":
    main()
