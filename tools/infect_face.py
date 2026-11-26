import os, struct, sys
import numpy as np
from PIL import Image

load = None


def srgb_to_lab(rgb):
    c = rgb / 255.0
    c = np.where(c > 0.04045, ((c + 0.055) / 1.055) ** 2.4, c / 12.92)
    m = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = c @ m.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def lab_to_srgb(lab):
    fy = (lab[..., 0] + 16) / 116
    fx, fz = fy + lab[..., 1] / 500, fy - lab[..., 2] / 200
    f = np.stack([fx, fy, fz], -1)
    xyz = np.where(f ** 3 > 0.008856, f ** 3, (f - 16 / 116) / 7.787) * np.array([0.95047, 1.0, 1.08883])
    m = np.array([[3.2406, -1.5372, -0.4986], [-0.9689, 1.8758, 0.0415], [0.0557, -0.2040, 1.0570]])
    c = np.clip(xyz @ m.T, 0, 1)
    c = np.where(c > 0.0031308, 1.055 * c ** (1 / 2.4) - 0.055, 12.92 * c)
    return np.clip(c * 255 + 0.5, 0, 255).astype(np.uint8)


def write_vtf(path, img, refl):
    w, h = img.size
    mips = []
    m = img
    while True:
        mips.append(m)
        if m.size == (1, 1):
            break
        m = m.resize((max(1, m.size[0] // 2), max(1, m.size[1] // 2)), Image.LANCZOS)
    hdr = bytearray(80)
    struct.pack_into("<4sIIIHHIHH", hdr, 0, b"VTF\0", 7, 2, 80, w, h, 0, 1, 0)
    struct.pack_into("<3f", hdr, 32, *refl)
    struct.pack_into("<f", hdr, 48, 1.0)
    struct.pack_into("<i", hdr, 52, 3)
    hdr[56] = len(mips)
    struct.pack_into("<i", hdr, 57, -1)
    hdr[61], hdr[62] = 0, 0
    struct.pack_into("<H", hdr, 63, 1)
    data = b"".join(mm.convert("RGB").tobytes("raw", "BGR") for mm in reversed(mips))
    with open(path, "wb") as f:
        f.write(bytes(hdr) + data)


def infect(faces, who):
    src_path = os.path.join(faces, who + "_facemap5.vtf")
    keep = os.path.join(faces, who + "_facemap5_clean.vtf")
    if not os.path.exists(keep):
        os.replace(src_path, keep)
    src = np.asarray(load(keep)[0], dtype=np.float64)
    tgt = []
    for v in ("", "2", "3", "4"):
        px = np.asarray(load(os.path.join(faces, who + "_facemap" + v + ".vtf"))[0], dtype=np.float64).reshape(-1, 3)
        r, g = px[:, 0], px[:, 1]
        tgt.append(px[~((r > 60) & (r > g * 1.6))])
    tgt = np.concatenate(tgt)
    sl, tl = srgb_to_lab(src), srgb_to_lab(tgt)
    s_skin = sl.reshape(-1, 3)
    s_skin = s_skin[s_skin[:, 0] > 45]
    t_skin = tl[tl[:, 0] > 38]
    sm, ss = s_skin.mean(0), s_skin.std(0) + 1e-6
    tm, ts = t_skin.mean(0), t_skin.std(0)
    out = lab_to_srgb((sl - sm) / ss * ts + tm)
    img = Image.fromarray(out, "RGB")
    lin = (np.asarray(img, dtype=np.float64) / 255.0) ** 2.2
    write_vtf(src_path, img, tuple(lin.reshape(-1, 3).mean(0)))
    print(f"{who}: L {sm[0]:.0f}->{tm[0]:.0f}  a {sm[1]:.1f}->{tm[1]:.1f}  b {sm[2]:.1f}->{tm[2]:.1f}  ->", src_path)
    return img


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Re-grade a clean facemap to match the infected faces")
    ap.add_argument("faces", help="materials/models/bloocobalt/citizens/facemaps folder")
    ap.add_argument("names", nargs="+", help="face names, e.g. sandro vance")
    ap.add_argument("--lib", action="append", default=[], help="folder containing vtf2png.py")
    a = ap.parse_args()
    sys.path[:0] = a.lib
    from vtf2png import load
    for who in a.names:
        infect(a.faces, who)
