import os, re, sys
path, modelname = sys.argv[1], sys.argv[2]
qc = open(path, encoding='latin1').read()
qc = qc.split('\n// --- LODs (build_lods.sh) ---')[0]
qc = re.sub(r'(?m)^\$modelname .*$', '$modelname "%s"' % modelname, qc)
smds = []
for m in re.finditer(r'(?m)^\s*(?:\$model\s+"[^"]+"|studio)\s+"([^"]+\.smd)"', qc):
    if m.group(1) not in smds: smds.append(m.group(1))
parent = dict((m.group(1), m.group(2)) for m in re.finditer(r'(?m)^\$definebone\s+"([^"]+)"\s+"([^"]*)"', qc))
helpers = [b for b in parent if re.search(r'_(Ulna|Wrist|Elbow|Bicep|Shoulder|Trapezius|Toe0)$', b)]
hands = [b for b in parent if re.search(r'Bip01_[RL]_Hand$', b)]
FACE = re.compile(r'(eyeball|pupil|glint|^mouth$)', re.I)
folder = os.path.dirname(path)
materials = []
for smd in smds:
    lines = open(os.path.join(folder, smd), encoding='latin1').read().split('\n')
    start = next((i for i, l in enumerate(lines) if l.strip() == 'triangles'), None)
    if start is None: continue
    for i in range(start + 1, len(lines), 4):
        name = lines[i].strip()
        if name == 'end' or not name: break
        if name not in materials: materials.append(name)
MATERIALS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'addon', 'materials')
cdmaterials = [m.replace('\\', '/').strip('/') for m in re.findall(r'(?m)^\$cdmaterials\s+"([^"]*)"', qc)]

def full_path(name):
    for d in cdmaterials:
        rel = (d + '/' + name) if d else name
        if os.path.exists(os.path.join(MATERIALS, rel + '.vmt')): return rel
    return name

face = [full_path(m) for m in materials if FACE.search(m)]
body = [m for m in materials if not FACE.search(m)]

def extend_skins(m):
    rows = [re.findall(r'"([^"]*)"', r) for r in re.findall(r'\{([^{}]*)\}', m.group(2))]
    if not rows: return m.group(0)
    head = rows[0][:rows[0].index(',')] if ',' in rows[0] else rows[0]
    cols = [i for i, n in enumerate(head) if not FACE.search(n)]
    out = []
    for r in rows:
        extra = ['%s_lod%d' % (r[i], n) for n in (1, 2) for i in cols]
        out.append('\t{ ' + ' '.join('"%s"' % x for x in r + extra) + ' }')
    return '%s\n{\n%s\n}' % (m.group(1), '\n'.join(out))

qc = re.sub(r'(\$texturegroup\s+"[^"]*")\s*\{((?:[^{}]|\{[^{}]*\})*)\}', extend_skins, qc)
THRESH = [20, 40, 75]
def block(head, n, bones):
    out = [head, '{']
    out += ['\treplacemodel "%s" "%s_lod%d.smd"' % (s, s[:-4], n) for s in smds]
    out += ['\tremovemesh "%s"' % f for f in face]
    out += ['\treplacematerial "%s" "%s_lod%d"' % (b, b, min(n, 2)) for b in body]
    out.append('\tnofacial')
    out += ['\tbonetreecollapse "%s"' % b for b in hands]
    if bones: out += ['\treplacebone "%s" "%s"' % (b, parent[b]) for b in helpers]
    out.append('}')
    return out
lines = ['', '// --- LODs (build_lods.sh) ---']
for n, t in enumerate(THRESH, 1): lines += block('$lod %d' % t, n, n >= 2)
lines += block('$shadowlod', len(THRESH), True)
open(path, 'w', encoding='latin1').write(qc.rstrip('\n') + '\n' + '\n'.join(lines) + '\n')
print('\n'.join(smds))
