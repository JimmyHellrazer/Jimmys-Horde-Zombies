import argparse
import glob
import os
import struct
import sys

from toolchain import ADDON

MODELS = os.path.join(ADDON, "models", "hordez", "citizens")
MATERIALS = os.path.join(ADDON, "materials")


def clean(path):
    return path.replace("\\", "/").strip("/").lower()


def cstr(data, at):
    return data[at:data.index(b"\0", at)].decode("latin1")


def known_materials(root):
    known = set()
    for folder, _, files in os.walk(root):
        for name in files:
            if name.lower().endswith(".vmt"):
                known.add(clean(os.path.relpath(os.path.join(folder, name[:-4]), root)))
    return known


def resolve(name, folders, known):
    for folder in folders:
        full = clean(clean(folder) + "/" + clean(name))
        if full in known:
            return full
    return None


def probes(name, folders, known):
    for count, folder in enumerate(folders, 1):
        if clean(clean(folder) + "/" + clean(name)) in known:
            return count - 1
    return len(folders)


def read_mdl(data):
    num_tex, tex_at, num_cd, cd_at, num_ref, num_fam, skin_at, num_parts, parts_at = struct.unpack_from("<9i", data, 204)
    folders = [cstr(data, struct.unpack_from("<i", data, cd_at + 4 * i)[0]) for i in range(num_cd)]
    names = [cstr(data, tex_at + 64 * i + struct.unpack_from("<i", data, tex_at + 64 * i)[0]) for i in range(num_tex)]
    refs = set()
    for part in range(num_parts):
        part_at = parts_at + 16 * part
        num_models, _, models_at = struct.unpack_from("<3i", data, part_at + 4)
        for model in range(num_models):
            model_at = part_at + models_at + 148 * model
            num_meshes, meshes_at = struct.unpack_from("<2i", data, model_at + 72)
            for mesh in range(num_meshes):
                refs.add(struct.unpack_from("<i", data, model_at + meshes_at + 116 * mesh)[0])
    used = set()
    for family in range(num_fam):
        row = struct.unpack_from("<%dh" % num_ref, data, skin_at + 2 * num_ref * family)
        used.update(row[ref] for ref in refs if ref < num_ref)
    return dict(tex_at=tex_at, cd_at=cd_at, folders=folders, names=names, used=used)


def read_vtx(data):
    num_lods, lists_at = struct.unpack_from("<2i", data, 20)
    out = []
    for lod in range(num_lods):
        head = lists_at + 8 * lod
        count, first = struct.unpack_from("<2i", data, head)
        for i in range(count):
            at = head + first + 6 * i
            material, name_at = struct.unpack_from("<hi", data, at)
            out.append((lod, at, material, cstr(data, at + name_at)))
    return num_lods, out


def misses(mdl, vtx, known):
    info = read_mdl(mdl)
    num_lods, swaps = read_vtx(vtx)
    total = sum(probes(name, info["folders"], known) for name in info["names"]) * 2
    for lod in range(num_lods):
        names = list(info["names"])
        for swap_lod, _, material, name in swaps:
            if swap_lod == lod and material < len(names):
                names[material] = name
        total += sum(probes(name, info["folders"], known) for name in names)
    return total


def append(data, cache, text):
    if text not in cache:
        cache[text] = len(data)
        data += text.encode("latin1") + b"\0"
    return cache[text]


def flatten(base, known):
    mdl = bytearray(open(base + ".mdl", "rb").read())
    vtx = bytearray(open(base + ".dx90.vtx", "rb").read())
    before = misses(mdl, vtx, known)
    info = read_mdl(mdl)
    folders = info["folders"]
    full = [resolve(name, folders, known) for name in info["names"]]
    lost = sorted(info["names"][i] for i in info["used"] if i < len(full) and not full[i])
    _, swaps = read_vtx(vtx)
    swap_full = [resolve(name, folders, known) for _, _, _, name in swaps]
    lost += sorted(set(swap[3] for swap, path in zip(swaps, swap_full) if not path))
    if lost:
        return "missing materials: " + ", ".join(lost)

    found = [path for path in full if path]
    if not found:
        return "no materials"

    full = [path or found[0] for path in full]
    parts = [path.split("/")[:-1] for path in full + swap_full]
    depth = 0
    while all(len(p) > depth for p in parts) and len(set(p[depth] for p in parts)) == 1:
        depth += 1

    root = "/".join(parts[0][:depth])
    cut = len(root) + 1 if root else 0
    cache = {}
    for i, path in enumerate(full):
        at = info["tex_at"] + 64 * i
        struct.pack_into("<i", mdl, at, append(mdl, cache, path[cut:]) - at)

    struct.pack_into("<i", mdl, info["cd_at"], append(mdl, cache, root + "/" if root else ""))
    struct.pack_into("<i", mdl, 212, 1)
    struct.pack_into("<i", mdl, 76, len(mdl))
    cache = {}
    for (_, at, _, _), path in zip(swaps, swap_full):
        struct.pack_into("<i", vtx, at + 2, append(vtx, cache, path[cut:]) - at)

    after = misses(mdl, vtx, known)
    if after:
        return "still misses %d lookups" % after

    if before:
        open(base + ".mdl", "wb").write(bytes(mdl))
        open(base + ".dx90.vtx", "wb").write(bytes(vtx))
    print("%s: %d materials, missed lookups %d -> %d" % (os.path.basename(base), len(full), before, after), flush=True)
    return None


def main():
    ap = argparse.ArgumentParser(description="Give every model material a single exact path so loading never searches for it")
    ap.add_argument("names", nargs="*", help="model names, default all")
    ap.add_argument("--models", default=MODELS, help="folder with the compiled models")
    ap.add_argument("--materials", default=MATERIALS, help="materials folder the models use")
    a = ap.parse_args()

    known = known_materials(a.materials)
    names = a.names or sorted(os.path.basename(p)[:-4] for p in glob.glob(os.path.join(a.models, "*.mdl")))
    failed = []
    for name in names:
        error = flatten(os.path.join(a.models, name), known)
        if error:
            failed.append(f"{name}: {error}")

    print("failed:", "; ".join(failed) if failed else "none")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
