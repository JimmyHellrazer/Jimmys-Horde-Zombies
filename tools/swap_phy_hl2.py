"""Swap the zombie ragdoll physics for the stock HL2 citizen ones (models/humans/group01/*.phy).
Run after patch_citizens.py. No recompile:
 * the .phy is copied and its checksum (header offset 12) set to the target .mdl's (offset 8),
   otherwise the engine rejects it;
 * each bone's physicsbone index in the .mdl (mstudiobone_t + 172) is remapped to the new solid order
   (own solid, else the nearest ancestor's), since the HL2 ragdoll has 15 solids vs the addon's 19.
Originals backed up in phy_backup_infected_citizens.
usage: swap_phy_hl2.py <hl2 group01 dir> <addon models/hordez/citizens dir>"""
import os, re, struct, sys, glob

def cstr(b, o):
    return b[o:b.index(b'\0', o)].decode('latin1')

def phy_solid_names(b):
    hs, _id, n, _ck = struct.unpack_from('<iiii', b, 0)
    off = hs
    for _ in range(n):
        off += 4 + struct.unpack_from('<i', b, off)[0]
    txt = b[off:].decode('latin1')
    solids = {}
    for blk in re.findall(r'solid\s*\{(.*?)\}', txt, re.S):
        idx = int(re.search(r'"index"\s*"(\d+)"', blk).group(1))
        solids[re.search(r'"name"\s*"([^"]+)"', blk).group(1).lower()] = idx
    return solids

src, dst = sys.argv[1], sys.argv[2]
for mdl in sorted(glob.glob(os.path.join(dst, '*.mdl'))):
    name = os.path.basename(mdl)[:-4]
    base = name.replace('_b', '')
    cand = os.path.join(src, base + '.phy')
    if not os.path.exists(cand):    # e.g. male_10 has no HL2 counterpart
        cand = os.path.join(src, ('female_01' if base.startswith('female') else 'male_01') + '.phy')
    m = bytearray(open(mdl, 'rb').read())
    ck = struct.unpack_from('<i', m, 8)[0]
    p = bytearray(open(cand, 'rb').read())
    struct.pack_into('<i', p, 12, ck)
    open(os.path.join(dst, name + '.phy'), 'wb').write(p)

    solids = phy_solid_names(bytes(p))
    nb, bi = struct.unpack_from('<ii', m, 156)
    names, parents = [], []
    for i in range(nb):
        o = bi + i * 216
        names.append(cstr(m, o + struct.unpack_from('<i', m, o)[0]).lower())
        parents.append(struct.unpack_from('<i', m, o + 4)[0])
    for i in range(nb):
        j = i
        while j >= 0 and names[j] not in solids:
            j = parents[j]
        struct.pack_into('<i', m, bi + i * 216 + 172, solids[names[j]] if j >= 0 else 0)
    open(mdl, 'wb').write(m)
    print(name, '<-', os.path.basename(cand), len(solids), 'solids')
