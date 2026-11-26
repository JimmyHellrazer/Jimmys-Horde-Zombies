import argparse, os, shutil, struct

ap = argparse.ArgumentParser(description="Copy the infected_citizens models in and point them at the retargeted animations")
ap.add_argument("source", help="models/bloocobalt/citizens folder of infected_citizens")
ap.add_argument("dest", nargs="?", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "addon",
    "models", "hordez", "citizens"))
args = ap.parse_args()
SRC, DST = args.source, args.dest
LIB = {"male": b"models/hordez/inf_m.mdl", "female": b"models/hordez/inf_f.mdl"}


def patch(path, lib):
    b = bytearray(open(path, "rb").read())
    i = lambda o: struct.unpack_from("<i", b, o)[0]
    n, idx = i(336), i(340)
    assert n >= 1, path
    so = idx + i(idx + 4)
    end = b.index(b"\0", so)
    assert len(lib) <= end - so, (path, end - so)
    b[so:end] = lib + b"\0" * (end - so - len(lib))
    struct.pack_into("<i", b, 336, 1)
    open(path, "wb").write(bytes(b))


os.makedirs(DST, exist_ok=True)
done = []
for fn in sorted(os.listdir(SRC)):
    if not fn.endswith(".mdl") or not fn.startswith(("male_", "female_")):
        continue
    base = fn[:-4]
    for ext in (".mdl", ".vvd", ".dx90.vtx", ".phy"):
        s = os.path.join(SRC, base + ext)
        if os.path.exists(s):
            shutil.copy2(s, os.path.join(DST, base + ext))
    patch(os.path.join(DST, fn), LIB["female" if base.startswith("female") else "male"])
    done.append(base)
print(len(done), "models:", " ".join(done))

MSRC = os.path.join(SRC, "..", "..", "..", "materials")
MDST = os.path.join(DST, "..", "..", "..", "materials")
for sub in (os.path.join("models", "bloocobalt"), "engine"):
    shutil.copytree(os.path.join(MSRC, sub), os.path.join(MDST, sub), dirs_exist_ok=True)
FACES = os.path.join(MDST, "models", "bloocobalt", "citizens", "facemaps")
for who in ("sandro", "vance"):
    shutil.copy2(os.path.join(FACES, who + "_facemap3.vmt"), os.path.join(FACES, who + "_facemap5.vmt"))
print("materials copied (clean facemap5 faces rerouted)")
