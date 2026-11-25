r"""Copy the infected_citizens models into horde_zombies and point their animation includes at the
retargeted L4D2 libraries (models/hordez/inf_m.mdl / inf_f.mdl). No recompile: the MDL's first
$includemodel string is overwritten in place (new path is shorter, null padded) and the include count
is set to 1, so the HL2 citizen anims (male_shared etc.) are dropped and their names can't clash.

    python patch_citizens.py

Copies .mdl / .vvd / .dx90.vtx / .phy only (GMod renders dx90; dx80/sw vtx are dead weight).
Materials (materials/models/bloocobalt + the eye textures in materials/engine) are copied too, so horde_zombies
is self-contained (model used with the author's permission). Run swap_phy_hl2.py afterwards (this re-copies the
addon's .phy).
"""
import os, shutil, struct

SRC = r"K:\SteamLibrary\steamapps\common\GarrysMod\garrysmod\addons\infected_citizens_129669178\models\bloocobalt\citizens"
DST = r"K:\SteamLibrary\steamapps\common\GarrysMod\garrysmod\addons\horde_zombies\models\hordez\citizens"
LIB = {"male": b"models/hordez/inf_m.mdl", "female": b"models/hordez/inf_f.mdl"}


def patch(path, lib):
    b = bytearray(open(path, "rb").read())
    i = lambda o: struct.unpack_from("<i", b, o)[0]
    n, idx = i(336), i(340)
    assert n >= 1, path
    so = idx + i(idx + 4)                      # sznameindex is relative to the modelgroup struct
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

# materials, so the addon no longer needs infected_citizens installed
MSRC = os.path.join(SRC, "..", "..", "..", "materials")
MDST = os.path.join(DST, "..", "..", "..", "materials")
for sub in (os.path.join("models", "bloocobalt"), "engine"):
    shutil.copytree(os.path.join(MSRC, sub), os.path.join(MDST, sub), dirs_exist_ok=True)
# two "_facemap5" textures in the addon are clean, uninfected HL2 faces (sandro = male_06 skins 4/9/14,
# vance = male_08). A colour re-grade (infect_face.py) didn't blend in, so those materials just use the
# character's 3rd infected face.
FACES = os.path.join(MDST, "models", "bloocobalt", "citizens", "facemaps")
for who in ("sandro", "vance"):
    shutil.copy2(os.path.join(FACES, who + "_facemap3.vmt"), os.path.join(FACES, who + "_facemap5.vmt"))
print("materials copied (clean facemap5 faces rerouted)")
