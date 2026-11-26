import math
import os
import re
import sys

LOOK = {
    "left_lowerer": 1, "right_lowerer": 1, "wrinkler": 0.85, "dilator": 0.7,
    "left_upper_raiser": 0.9, "right_upper_raiser": 0.9, "left_lid_tightener": 0.8, "right_lid_tightener": 0.8,
    "left_stretcher": 0.6, "right_stretcher": 0.6, "left_corner_depressor": 0.4, "right_corner_depressor": 0.4,
    "left_part": 0.6, "right_part": 0.6, "jaw_drop": 0.15,
}

qc_path = sys.argv[1]
folder = os.path.dirname(qc_path)
qc = open(qc_path, encoding="latin1").read()

model = re.search(r'\$model\s+"[^"]+"\s+"([^"]+)"\s*\{', qc)
if not model:
    print("no flex model")
    sys.exit(0)

start = model.end()
depth, i = 1, start
while depth:
    depth += {"{": 1, "}": -1}.get(qc[i], 0)
    i += 1
body = qc[start:i - 1]

controllers = re.findall(r'flexcontroller\s+\S+\s+range\s+\S+\s+\S+\s+"([^"]+)"', body)
values = {c: LOOK.get(c, 0.0) for c in controllers}
rules = re.findall(r'^\s*%(\w+)\s*=\s*(.+)$', body, re.M)
class Scope(dict):
    def __missing__(self, key):
        return 0.0


weights = {}
for _ in range(2):
    for name, expr in rules:
        code = re.sub(r"%(\w+)", r"_\1", expr)
        scope = Scope(values)
        scope.update({"_" + k: v for k, v in weights.items()})
        try:
            weights[name] = eval(code, {"__builtins__": {}}, scope)
        except ZeroDivisionError:
            weights[name] = 0.0

vta_name = re.search(r'flexfile\s+"([^"]+)"', body).group(1)
frames = {}
for m in re.finditer(r'flex(pair)?\s+"([^"]+)"\s+(?:\S+\s+)?frame\s+(\d+)', body):
    pair, name, frame = m.group(1), m.group(2), int(m.group(3))
    w = (weights.get(name + "L", 0) + weights.get(name + "R", 0)) / 2 if pair else weights.get(name, 0)
    w = max(0.0, min(1.0, w))
    if w > 0:
        frames[frame] = frames.get(frame, 0) + w

lines = open(os.path.join(folder, vta_name), encoding="latin1").read().split("\n")
section = lines.index(next(l for l in lines if l.strip() == "vertexanimation"))
time, base, deltas = None, {}, {}
for line in lines[section + 1:]:
    parts = line.split()
    if not parts or parts[0] == "end":
        if parts and parts[0] == "end":
            break
        continue
    if parts[0] == "time":
        time = int(parts[1])
        continue
    idx = int(parts[0])
    vals = [float(v) for v in parts[1:7]]
    if time == 0:
        base[idx] = vals
    elif time in frames and idx in base:
        w = frames[time]
        key = tuple(round(c, 3) for c in base[idx][:3])
        acc = deltas.setdefault(key, [0.0] * 6)
        for k in range(6):
            acc[k] += (vals[k] - base[idx][k]) * w

ref = re.search(r'\$model\s+"[^"]+"\s+"([^"]+)"', qc).group(1)
smd_path = os.path.join(folder, ref)
smd = open(smd_path, encoding="latin1").read().split("\n")
tri = smd.index("triangles")
moved = 0
for n in range(tri + 1, len(smd)):
    parts = smd[n].split()
    if len(parts) < 9:
        continue
    key = tuple(round(float(c), 3) for c in parts[1:4])
    d = deltas.get(key)
    if not d:
        continue
    pos = [float(parts[1 + k]) + d[k] for k in range(3)]
    nrm = [float(parts[4 + k]) + d[3 + k] for k in range(3)]
    length = math.sqrt(sum(c * c for c in nrm)) or 1.0
    nrm = [c / length for c in nrm]
    parts[1:7] = [f"{c:.6f}" for c in pos + nrm]
    smd[n] = " ".join(parts)
    moved += 1
open(smd_path, "w", encoding="latin1").write("\n".join(smd))

stripped = re.sub(r'\n\s*flexfile\s+"[^"]+"\s*\{[^}]*\}', "", body)
stripped = re.sub(r'(?m)^\s*(flexcontroller|localvar|%).*\n', "", stripped)
qc = qc[:start] + stripped + qc[i - 1:]
open(qc_path, "w", encoding="latin1").write(qc)
print(f"baked {len(frames)} flex frames into {moved} vertices")
