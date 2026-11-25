import os
import re
import sys

root = sys.argv[1]
SKIP = re.compile(r"(eyeball|pupil|glint|_lod\d)", re.I)
HEAVY = re.compile(r'^\s*"?\$(bumpmap|normalmap|phong\w*|rimlight\w*|envmap\w*|normalmapalphaenvmapmask|basemapalphaphongmask|selfillum\w*|detail\w*)"?\b.*$', re.I | re.M)
NOCULL = re.compile(r'^\s*"?\$nocull"?\b.*$', re.I | re.M)
written = 0
for folder, _, files in os.walk(root):
    for name in files:
        if not name.lower().endswith(".vmt") or SKIP.search(name):
            continue
        text = open(os.path.join(folder, name), encoding="latin1").read()
        if not re.match(r'\s*"?vertexlitgeneric"?', text, re.I):
            continue
        base = name[:-4]
        light = NOCULL.sub("", text)
        cheap = HEAVY.sub("", light)
        open(os.path.join(folder, base + "_lod1.vmt"), "w", encoding="latin1").write(light)
        open(os.path.join(folder, base + "_lod2.vmt"), "w", encoding="latin1").write(cheap)
        written += 2
print(f"{written} lod materials")
