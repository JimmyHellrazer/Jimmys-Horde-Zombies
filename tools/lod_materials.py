import os
import re
import sys

root = sys.argv[1]
SKIP = re.compile(r"(eyeball|pupil|glint|_lod\d)", re.I)
HEAVY = re.compile(r'^\s*"?\$(bumpmap|normalmap|phong\w*|rimlight\w*|envmap\w*|normalmapalphaenvmapmask|basemapalphaphongmask|selfillum\w*|detail\w*|halflambert)"?\b.*$', re.I | re.M)
NOCULL = re.compile(r'^\s*"?\$nocull"?\b.*$', re.I | re.M)
written = 0


def tidy(text):
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n\s*\n(\s*\n)+", "\n\n", text)
    text = re.sub(r"\{\n\s*\n", "{\n", text)
    return re.sub(r"\n\s*\n(\s*\})", r"\n\1", text)


for folder, _, files in os.walk(root):
    for name in files:
        if not name.lower().endswith(".vmt") or SKIP.search(name):
            continue
        text = open(os.path.join(folder, name), encoding="latin1").read()
        text = re.sub(r"[ \t]*//[^\n]*", "", text)
        if not re.match(r'\s*"?(vertexlitgeneric|unlitgeneric)"?', text, re.I):
            continue
        base = name[:-4]
        light = NOCULL.sub("", text)
        cheap = HEAVY.sub("", light)
        if re.match(r'\s*"?unlitgeneric"?', text, re.I):
            light = cheap = re.sub(r"\n\s*\n", "\n", cheap)
        open(os.path.join(folder, base + "_lod1.vmt"), "w", encoding="latin1").write(tidy(light))
        open(os.path.join(folder, base + "_lod2.vmt"), "w", encoding="latin1").write(tidy(cheap))
        written += 2
print(f"{written} lod materials")
