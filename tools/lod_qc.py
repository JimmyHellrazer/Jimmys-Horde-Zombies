# Step of build_lods.sh: patches a Crowbar-decompiled body QC in place.
#   lod_qc.py <file.qc> <modelname>   -> prints the reference SMDs that need LOD copies, one per line
# Sets $modelname and appends three $lod levels plus a $shadowlod that swap every mesh for its decimated copy,
# drop facial flexes (flexed heads are skinned on the CPU) and fold finger / twist-helper bones into their
# parents so distant zombies also set up fewer bones.
import re, sys
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
THRESH = [20, 40, 75]
def block(head, n, bones):
    out = [head, '{']
    out += ['\treplacemodel "%s" "%s_lod%d.smd"' % (s, s[:-4], n) for s in smds]
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
