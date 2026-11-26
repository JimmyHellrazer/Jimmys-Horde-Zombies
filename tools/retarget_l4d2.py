import argparse, math, os, re, sys

SRC = CIT = OUT = REFS = None
Mdl = None

SETS = {
    "male": dict(qc="anim_common.qc", cit="male_01.mdl", name="hordez/inf_m.mdl", ref="anim_common.mdl"),
    "female": dict(qc="anim_common_female.qc", cit="female_01.mdl", name="hordez/inf_f.mdl",
                   ref="anim_common_female.mdl"),
}
ROOT = "ValveBiped.Bip01_Pelvis"

ROMERO_DIR = r"K:\romero\models\xdreanims\ANIMS"
ROMERO = {
    "male": ["ci_male_slot_003.qc", "ci_male_slot_008.qc", "ci_male_slot_027.qc"],
    "female": ["ci_female_slot_003.qc", "ci_female_slot_027.qc"],
}
ROMERO_PREFIX = "Romero_"
ROMERO_SKIP = re.compile(r"aim_matrix", re.I)
LEG = ["ValveBiped.Bip01_L_Calf", "ValveBiped.Bip01_L_Foot"]


def leg_len(mdl):
    b = {x["name"]: x for x in mdl.bones}
    return sum(abs(b[n]["pos"][0]) for n in LEG)


def is_delta(lines):
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
    return seen > 0 and nonzero <= max(1, seen // 10)


def qc_delta_files(qc_lines):
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
    names, out, mode = {}, [], None
    with open(src) as f:
        lines = f.read().splitlines()
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
    x, y, z = b["pos"]
    rx, ry, rz = (math.degrees(a) for a in b["rot"])
    return (f'$definebone "{b["name"]}" "{parent_name}" {x:.6f} {y:.6f} {z:.6f} '
            f"{ry:.6f} {rz:.6f} {rx:.6f} 0 0 0 0 0 0")


def qc_blocks(lines):
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
                continue
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
    src_mdl = Mdl(os.path.join(REFS, cfg["ref"]))
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
    ap = argparse.ArgumentParser(description="Retarget the L4D2 common infected animations onto the citizen rig")
    ap.add_argument("source", help="Crowbar decompile of the L4D2 infected animations (anim_common*.qc)")
    ap.add_argument("citizens", help="models/bloocobalt/citizens folder of infected_citizens")
    ap.add_argument("refs", help="folder with L4D2's anim_common.mdl and anim_common_female.mdl")
    ap.add_argument("out", help="output folder")
    ap.add_argument("--lib", action="append", default=[], help="folder containing mdl_decompile.py")
    ap.add_argument("--set", default="both", choices=["male", "female", "both"])
    a = ap.parse_args()
    sys.path[:0] = a.lib
    from mdl_decompile import Mdl
    SRC, CIT, REFS, OUT = a.source, a.citizens, a.refs, a.out
    for s in (["male", "female"] if a.set == "both" else [a.set]):
        build(s)
