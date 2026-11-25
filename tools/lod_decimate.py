# Blender (headless) step of build_lods.sh: reads reference SMDs, writes decimated copies <name>_lod<N>.smd.
#   blender -b --python lod_decimate.py -- <ratio1,ratio2,...> <file.smd> [file.smd ...]
# Own SMD reader / writer (no add-on needed). Vertices are welded by position so the surface decimates as one
# skin; UVs and bone weights ride along; open borders (neck, wrists, waist) are held in place so the body
# parts still meet at lower detail.
import bpy, sys, os

def read_smd(path):
    lines = open(path, encoding='latin1').read().split('\n')
    t = next(i for i, l in enumerate(lines) if l.strip() == 'triangles')
    head = lines[:t]
    tris = []
    i = t + 1
    while i < len(lines) and lines[i].strip() != 'end':
        mat = lines[i].strip()
        vs = []
        for k in range(1, 4):
            p = lines[i + k].split()
            pos = tuple(float(x) for x in p[1:4])
            uv = (float(p[7]), float(p[8]))
            n = int(p[9]) if len(p) > 9 else 0
            links = [(int(p[10 + 2 * j]), float(p[11 + 2 * j])) for j in range(n)]
            if not links: links = [(int(p[0]), 1.0)]
            vs.append((pos, uv, links))
        tris.append((mat, vs))
        i += 4
    return head, tris

def build(name, tris):
    key, verts, weights, faces, uvs, mats, matidx = {}, [], [], [], [], [], []
    for mat, vs in tris:
        if mat not in mats: mats.append(mat)
        f = []
        for pos, uv, links in vs:
            k = (round(pos[0], 4), round(pos[1], 4), round(pos[2], 4))
            if k not in key:
                key[k] = len(verts); verts.append(pos); weights.append(links)
            f.append(key[k])
        if len(set(f)) < 3: continue
        faces.append(f); uvs.append([v[1] for v in vs]); matidx.append(mats.index(mat))
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.update()
    for m in mats: me.materials.append(bpy.data.materials.new(m))
    uvl = me.uv_layers.new(name='uv')
    # from_pydata may drop / reorder nothing for valid tris; map by polygon index
    for p in me.polygons:
        p.material_index = matidx[p.index]
        p.use_smooth = True
        src = {faces[p.index][j]: uvs[p.index][j] for j in range(3)}
        for li in p.loop_indices:
            uvl.data[li].uv = src[me.loops[li].vertex_index]
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    groups = {}
    for vi, links in enumerate(weights):
        for b, w in links:
            g = groups.get(b)
            if g is None: g = groups[b] = ob.vertex_groups.new(name=str(b))
            g.add([vi], w, 'REPLACE')
    # border vertices (edges with one face) are kept: weight 0 in the decimation group
    count = {}
    for p in me.polygons:
        for ek in p.edge_keys: count[ek] = count.get(ek, 0) + 1
    border = set()
    for ek, c in count.items():
        if c == 1: border.update(ek)
    dg = ob.vertex_groups.new(name='__dec')
    dg.add([v.index for v in me.vertices if v.index not in border], 1.0, 'REPLACE')
    if border: dg.add(list(border), 0.0, 'REPLACE')
    return ob, mats

def write_smd(path, head, ob, mats, ratio):
    mod = ob.modifiers.new('dec', 'DECIMATE')
    mod.decimate_type = 'COLLAPSE'
    mod.ratio = ratio
    mod.use_collapse_triangulate = True
    mod.vertex_group = '__dec'
    mod.vertex_group_factor = 4.0
    dgraph = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(dgraph)
    me = ev.to_mesh()
    me.calc_loop_triangles()
    uvl = me.uv_layers.active.data
    cn = me.corner_normals
    gname = {g.index: g.name for g in ob.vertex_groups}
    out = list(head) + ['triangles']
    ntri = 0
    for lt in me.loop_triangles:
        out.append(mats[lt.material_index])
        for li in lt.loops:
            v = me.vertices[me.loops[li].vertex_index]
            links = [(int(gname[g.group]), g.weight) for g in v.groups if gname[g.group] != '__dec' and g.weight > 0.001]
            links.sort(key=lambda x: -x[1])
            links = links[:3] or [(0, 1.0)]
            tot = sum(w for _, w in links)
            n = cn[li].vector
            uv = uvl[li].uv
            out.append('  %d %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %d %s' % (links[0][0], v.co.x, v.co.y, v.co.z, n.x, n.y, n.z,
                uv.x, uv.y, len(links), ' '.join('%d %.6f' % (b, w / tot) for b, w in links)))
        ntri += 1
    out += ['end', '']
    open(path, 'w', encoding='latin1').write('\n'.join(out))
    ev.to_mesh_clear()
    ob.modifiers.remove(mod)
    return ntri

args = sys.argv[sys.argv.index('--') + 1:]
ratios = [float(x) for x in args[0].split(',')]
for path in args[1:]:
    head, tris = read_smd(path)
    ob, mats = build(os.path.basename(path), tris)
    res = []
    for n, r in enumerate(ratios, 1):
        res.append(write_smd(path[:-4] + '_lod%d.smd' % n, head, ob, mats, r))
    print('LOD %-28s %5d tris -> %s' % (os.path.basename(path), len(tris), ' / '.join(str(x) for x in res)))
    bpy.data.objects.remove(ob)
