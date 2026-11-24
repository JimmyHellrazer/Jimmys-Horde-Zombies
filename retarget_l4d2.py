r"""Retarget L4D2 common-infected animations onto the infected_citizens (HL2 ValveBiped) skeleton
and write a compile-ready animation-library QC for each.

    python retarget_l4d2.py [--set male|female|both]

Input:  Crowbar decompile in K:\jimmyproject\l4d2_rip\models\infected\steven!\ (anim_common*.qc + *_anims\*.smd)
Output: K:\jimmyproject\hordez\build\<set>\  (anim_infected_<m|f>.qc + anims\*.smd)

Method (both rigs are ValveBiped with identical bone axis conventions):
- every bone keeps the L4D2 local ROTATION per frame;
- every non-root bone takes the citizen's rest TRANSLATION (so limbs keep citizen proportions);
- the pelvis (root) translation is scaled by citizen leg length / L4D2 leg length, so root motion
  and hip height match and feet don't slide.
- $definebone uses the citizen rest pose (rest values = what the engine falls back to for omitted data).
QC changes: new $modelname, no hitboxes / physics / materials (the citizen model owns those),
no AE_CL_PLAYSOUND events (L4D2 sound names don't exist in GMod).
Citizen extra bones (finger 2nd/3rd joints, ulna/bicep helpers) are not in the library, so they stay at rest.
"""
import argparse, math, os, re, sys

sys.path.insert(0, r"K:\jimmyproject\codport\tools")
sys.path.insert(0, r"K:\jimmyproject\codport")
from mdl_decompile import Mdl  # noqa: E402

SRC = r"K:\jimmyproject\l4d2_rip\models\infected\steven!"
CIT = r"K:\SteamLibrary\steamapps\common\GarrysMod\garrysmod\addons\infected_citizens_129669178\models\bloocobalt\citizens"
OUT = r"K:\jimmyproject\hordez\build"

SETS = {
    "male": dict(qc="anim_common.qc", cit="male_01.mdl", name="hordez/inf_m.mdl",
                 ref=r"K:\jimmyproject\l4d2_rip\models\infected\anim_common.mdl"),
    "female": dict(qc="anim_common_female.qc", cit="female_01.mdl", name="hordez/inf_f.mdl",
                   ref=r"K:\jimmyproject\l4d2_rip\models\infected\anim_common_female.mdl"),
}
ROOT = "ValveBiped.Bip01_Pelvis"

# Romero shamblers (L4D2 workshop mod "George Romero Dead Mode", UndeadTabaco / Cidadao_de_Mal): its
# "xdreanims" slot models override sequences by name. They are imported into the same libraries under a
# "Romero_" prefix (no new citizen copies needed). First slot listed wins for duplicate names, as in-game.
ROMERO_DIR = r"K:\romero\models\xdreanims\ANIMS"
ROMERO = {
    "male": ["ci_male_slot_003.qc", "ci_male_slot_008.qc", "ci_male_slot_027.qc"],
    "female": ["ci_female_slot_003.qc", "ci_female_slot_027.qc"],
}
ROMERO_PREFIX = "Romero_"
ROMERO_SKIP = re.compile(r"aim_matrix", re.I)   # upper-body aim layers: not used by the NextBot
LEG = ["ValveBiped.Bip01_L_Calf", "ValveBiped.Bip01_L_Foot"]   # thigh->calf, calf->foot lengths


def leg_len(mdl):
    b = {x["name"]: x for x in mdl.bones}
    return sum(abs(b[n]["pos"][0]) for n in LEG)


def is_delta(lines):
    """True when every non-root bone in the first frame has a (near) zero position."""
    seen, nonzero, in_skel, frame = 0, 0, False, 0
    for ln in lines:
        s = ln.strip()
        if s == "skeleton":
            in_skel = True
            continue
        if not in_skel:
            continue
        if s.startswith("time"):
            frame += 1
            if frame > 1:
                break
            continue
        if s == "end":
            break
        p = s.split()
        if int(p[0]) == 0:
            continue
        seen += 1
        if abs(float(p[1])) + abs(float(p[2])) + abs(float(p[3])) > 0.01:
            nonzero += 1
    # tolerant: some L4D2 deltas keep a small offset on one bone (female Melee_Moving01_Delta: Spine 0.5u),
    # which made the strict test miss them and doubled the spine on female attacks (2026-11-23)
    return seen > 0 and nonzero <= max(1, seen // 10)


def qc_delta_files(qc_lines):
    """SMD file names used by $sequence/$animation blocks marked delta (authoritative, from the source QC)."""
    out, block, files, depth = set(), None, [], 0
    for ln in qc_lines:
        s = ln.strip()
        if block is None and s.startswith(("$sequence", "$animation")):
            block, files, depth = [], [], 0
        if block is not None:
            block.append(s)
            files += [os.path.basename(f.replace("\\", "/")).lower() for f in re.findall(r'"([^"]+\.smd)"', s)]
            depth += s.count("{") - s.count("}")
            if depth <= 0 and "{" in "".join(block):
                if any(b == "delta" for b in block):
                    out.update(files)
                block = None
    return out


def retarget_smd(src, dst, rest, scale, force_delta=False):
    """rest: name -> (x,y,z) citizen local pos. Rewrites positions, keeps rotations."""
    names, out, mode = {}, [], None
    with open(src) as f:
        lines = f.read().splitlines()
    # Delta animations (aim matrices, leans, layers, correctives) store per-bone OFFSETS: their non-root
    # positions are ~0. Writing rest positions into them made every layered sequence add a second copy
    # of each bone offset (stretched "expanding" zombies, 2026-11-22). Leave their positions alone.
    delta = force_delta or is_delta(lines)
    for ln in lines:
        s = ln.strip()
        if s in ("nodes", "skeleton", "triangles"):
            mode = s
            out.append(ln)
            continue
        if s == "end":
            mode = None
            out.append(ln)
            continue
        if mode == "nodes":
            m = re.match(r'\s*(\d+)\s+"([^"]+)"\s+(-?\d+)', ln)
            names[int(m.group(1))] = m.group(2)
            out.append(ln)
        elif mode == "skeleton" and not s.startswith("time"):
            p = s.split()
            bi = int(p[0])
            v = [float(x) for x in p[1:7]]
            n = names[bi]
            if n == ROOT:
                v[0] *= scale; v[1] *= scale; v[2] *= scale
            elif n in rest and not delta:
                v[0], v[1], v[2] = rest[n]
            out.append(f"  {bi} " + " ".join(f"{x:.6f}" for x in v))
        else:
            out.append(ln)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w", newline="\n") as f:
        f.write("\n".join(out) + "\n")


def definebone_line(b, parent_name):
    # $definebone angles are (rot.y, rot.z, rot.x) in degrees (checked against Crowbar output)
    x, y, z = b["pos"]
    rx, ry, rz = (math.degrees(a) for a in b["rot"])
    return (f'$definebone "{b["name"]}" "{parent_name}" {x:.6f} {y:.6f} {z:.6f} '
            f"{ry:.6f} {rz:.6f} {rx:.6f} 0 0 0 0 0 0")


def qc_blocks(lines):
    """Top-level $animation / $sequence / $weightlist blocks: [(kind, name, [lines])]."""
    out, i = [], 0
    while i < len(lines):
        s = lines[i].strip()
        kind = next((k for k in ("$animation", "$sequence", "$weightlist") if s.startswith(k + " ")), None)
        if not kind:
            i += 1
            continue
        name = re.findall(r'"([^"]*)"', s)[0]
        blk, depth, opened = [], 0, False
        while i < len(lines):
            ln = lines[i]
            blk.append(ln)
            depth += ln.count("{") - ln.count("}")
            opened = opened or "{" in ln
            i += 1
            if opened and depth <= 0:
                break
        out.append((kind, name, blk))
    return out


def romero_import(setname, outdir, rest, scale):
    """Retarget the Romero slot animations and return QC lines defining them with the Romero_ prefix."""
    taken, picked = set(), []
    for qcname in ROMERO.get(setname, []):
        qcp = os.path.join(ROMERO_DIR, qcname)
        animdir = qcname[:-3] + "_anims"
        for kind, name, blk in qc_blocks(open(qcp, encoding="latin1").read().splitlines()):
            if ROMERO_SKIP.search(name) or name in taken:
                continue
            taken.add(name)
            picked.append((kind, name, blk, animdir))

    def rn(n):
        return ("@" + ROMERO_PREFIX + n[1:]) if n.startswith("@") else ROMERO_PREFIX + n

    q, n = ["", "// ---- Romero shambler set (prefixed copies, see ROMERO in retarget_l4d2.py) ----"], 0
    for kind, name, blk, animdir in picked:
        is_delta = any(l.strip() == "delta" for l in blk)
        for ln in blk:
            st = ln.strip()
            if st.startswith("activity ") or "AE_CL_PLAYSOUND" in st or "event 5004" in st:
                continue
            refs = re.findall(r'"([^"]*)"', ln)
            if any(ROMERO_SKIP.search(r) for r in refs):
                continue   # a layer / weightlist of the skipped aim matrix
            for r in set(refs):
                if r in taken:
                    ln = ln.replace('"%s"' % r, '"%s"' % rn(r))
            for smd in re.findall(r'"([^"]+\.smd)"', ln):
                base = smd.replace("\\", "/").split("/")[-1]
                src = os.path.join(ROMERO_DIR, animdir, base)
                retarget_smd(src, os.path.join(outdir, "anims", "romero", base), rest, scale, is_delta)
                n += 1
                ln = ln.replace(smd, "anims\\romero\\" + base)
            q.append(ln)
        q.append("")
    print(f"[{setname}] romero: {len(picked)} blocks, {n} smds")
    return q


def build(setname):
    cfg = SETS[setname]
    cit = Mdl(os.path.join(CIT, cfg["cit"]))
    src_mdl = Mdl(cfg["ref"])
    scale = leg_len(cit) / leg_len(src_mdl)
    cb = {b["name"]: b for b in cit.bones}
    rest = {n: tuple(b["pos"]) for n, b in cb.items() if n != ROOT}
    print(f"[{setname}] leg scale {scale:.4f}")

    outdir = os.path.join(OUT, setname)
    qc_src = open(os.path.join(SRC, cfg["qc"])).read().splitlines()
    animdir = cfg["qc"][:-3] + "_anims"
    q, skip_block, depth = [], False, 0
    for ln in qc_src:
        s = ln.strip()
        if skip_block:
            depth += s.count("{") - s.count("}")
            if depth <= 0 and "}" in s:
                skip_block = False
            continue
        if s.startswith("$modelname"):
            q.append(f'$modelname "{cfg["name"]}"'); continue
        if s.startswith(("$hboxset", "$hbox", "$cdmaterials", "$surfaceprop", "$contents")):
            continue
        if s.startswith("$collisionjoints"):
            skip_block, depth = True, 0
            continue
        if s.startswith("$definebone"):
            name = re.findall(r'"([^"]*)"', s)[0]
            if name != ROOT and name in cb:
                b = cb[name]
                q.append(definebone_line(b, cit.bones[b["parent"]]["name"] if b["parent"] >= 0 else ""))
                continue
        if "AE_CL_PLAYSOUND" in s:
            continue
        q.append(ln.replace(animdir + "\\", "anims\\"))
    # collisionjoints opens with a line of its own before '{'
    os.makedirs(outdir, exist_ok=True)
    q += romero_import(setname, outdir, rest, scale)
    qc_out = os.path.join(outdir, os.path.basename(cfg["name"])[:-4] + ".qc")
    with open(qc_out, "w", newline="\n") as f:
        f.write("\n".join(q) + "\n")

    n = 0
    deltas = qc_delta_files(qc_src)
    for fn in os.listdir(os.path.join(SRC, animdir)):
        if fn.lower().endswith(".smd"):
            src = os.path.join(SRC, animdir, fn)
            with open(src) as f:
                heur = is_delta(f.read().splitlines())
            if (fn.lower() in deltas) != heur:
                print(f"  delta: qc={fn.lower() in deltas} heuristic={heur} {fn}")
            retarget_smd(src, os.path.join(outdir, "anims", fn), rest, scale, fn.lower() in deltas)
            n += 1
    print(f"[{setname}] {n} smds -> {outdir}; qc {qc_out}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", default="both", choices=["male", "female", "both"])
    a = ap.parse_args()
    for s in (["male", "female"] if a.set == "both" else [a.set]):
        build(s)
