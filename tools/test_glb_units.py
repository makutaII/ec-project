#!/usr/bin/env python3
"""Проверка правил glb_preflight для узлов тележек (unit_<n>, wheel_<n>_<k>, extras radius), цикла привода (extras ec_cycle)
и допуска на реборду:  python tools/test_glb_units.py

Берёт data/models/wagon_coal_01/wagon_coal_01.glb, достраивает в нём узлы и анимацию и прогоняет tools/glb_preflight.py.
"""
import json
import math
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "data", "models", "wagon_coal_01", "wagon_coal_01.glb")
PREFLIGHT = os.path.join(HERE, "glb_preflight.py")
fails = []


def check(label, ok, extra=""):
    print(("PASS " if ok else "FAIL ") + label + ("" if ok else "  " + str(extra)))
    if not ok:
        fails.append(label)


def load(path):
    d = open(path, "rb").read()
    jl = struct.unpack("<I", d[12:16])[0]
    j = json.loads(d[20:20 + jl])
    off = 20 + jl
    bl = struct.unpack("<I", d[off:off + 4])[0]
    return j, d[off + 8:off + 8 + bl]


def save(path, j, binb):
    js = json.dumps(j, separators=(",", ":")).encode("utf-8")
    js += b" " * ((4 - len(js) % 4) % 4)
    binb += b"\0" * ((4 - len(binb) % 4) % 4)
    total = 12 + 8 + len(js) + 8 + len(binb)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, total))
        f.write(struct.pack("<I4s", len(js), b"JSON") + js)
        f.write(struct.pack("<I4s", len(binb), b"BIN\0") + binb)


def add_accessor(j, binb, values, comp_type, label):
    flat = [x for v in values for x in (v if isinstance(v, (tuple, list)) else (v,))]
    data = struct.pack("<%df" % len(flat), *flat)
    start = len(binb)
    binb += data
    binb += b"\0" * ((4 - len(binb) % 4) % 4)
    j["bufferViews"].append({"buffer": 0, "byteOffset": start, "byteLength": len(data)})
    j["accessors"].append({"bufferView": len(j["bufferViews"]) - 1, "componentType": 5126, "count": len(values), "type": comp_type})
    j["buffers"][0]["byteLength"] = len(binb)
    return len(j["accessors"]) - 1, binb


def build(radius=0.9, with_radius=True, close_cycle=True, interp="LINEAR", pos_radius=None):
    j, binb = load(SRC)
    nodes = j["nodes"]
    body = next(i for i, n in enumerate(nodes) if (n.get("extras") or {}).get("role") == "body")
    abs_y = 1.061
    y = (radius if pos_radius is None else pos_radius) - abs_y   # положение узла по высоте оси, radius в extras задаётся отдельно

    def add(node):
        nodes.append(node)
        return len(nodes) - 1

    w1 = add({"name": "wheel_a", "translation": [0, 0, -1.5], "extras": dict({"role": "wheel_1_1"}, **({"radius": radius} if with_radius else {}))})
    w2 = add({"name": "wheel_b", "translation": [0, 0, 1.5], "extras": {"role": "wheel_1_2", "radius": radius}})
    u = add({"name": "unit_1", "translation": [0, y, 0], "children": [w1, w2], "extras": {"role": "unit_1"}})
    rod = add({"name": "drv_rod", "translation": [0.5, 0, 0], "extras": {"role": "drv_rod", "ec_cycle": "drive"}})
    nodes[body].setdefault("children", []).extend([u, rod])
    n = 8
    times = [k / 24.0 for k in range(n + 1)]
    pos = [(0.5 + 0.1 * math.cos(2 * math.pi * k / n), 0.1 * math.sin(2 * math.pi * k / n), 0.0) for k in range(n + 1)]
    if not close_cycle:
        pos[-1] = (0.9, 0.0, 0.0)
    rots = [(0.0, 0.0, math.sin(math.radians(5) * math.sin(2 * math.pi * k / n)), math.cos(math.radians(5) * math.sin(2 * math.pi * k / n))) for k in range(n + 1)]
    a_t, binb = add_accessor(j, binb, times, "SCALAR", "t")
    a_p, binb = add_accessor(j, binb, pos, "VEC3", "p")
    a_r, binb = add_accessor(j, binb, rots, "VEC4", "r")
    j.setdefault("animations", []).append({
        "name": "mech_drive",
        "samplers": [{"input": a_t, "output": a_p, "interpolation": interp}, {"input": a_t, "output": a_r, "interpolation": interp}],
        "channels": [{"sampler": 0, "target": {"node": rod, "path": "translation"}}, {"sampler": 1, "target": {"node": rod, "path": "rotation"}}]})
    out = os.path.join(tempfile.mkdtemp(), "t.glb")
    save(out, j, binb)
    r = subprocess.run([sys.executable, PREFLIGHT, out], capture_output=True)
    return (r.stdout + r.stderr).decode("utf-8", "replace")


def lines(txt, key):
    return [l for l in txt.split("\n") if key in l]


good = build()
check("исправный узел: preflight не падает", "Итог:" in good, good[-300:])
check("исправный узел: заготовка BogieConfig", len(lines(good, "Заготовка BogieConfig из узла 'unit_1'")) == 1 and "[-1.500, 1.500]" in good, lines(good, "unit_1"))
check("исправный узел: wheel_pair_position для двух симметричных осей", "wheel_pair_position = Vector3(0, 0.900, 1.500)" in good)
check("цикл: заготовка MechanismConfig", len(lines(good, "Цикл привода 'mech_drive'")) == 1 and "8 кадров на оборот" in good, lines(good, "Цикл"))
check("цикл замкнутый: нет предупреждений о незамкнутости и интерполяции", not lines(good, "не замкнут") and not lines(good, "интерполяция не Linear"))
check("цикл: нет шума про сдвиг и поворот или нулевое движение", not lines(good, "и сдвиг, и поворот") and not lines(good, "движения между первым"))
check("исправный узел: нет ERROR по колёсам и узлам", not [l for l in lines(good, "[ERROR]") if "Колёсная" in l or "Узел" in l])

bad = build(close_cycle=False)
check("цикл не замкнут: предупреждение", len(lines(bad, "не замкнут")) == 1, lines(bad, "Цикл"))

lin = build(interp="STEP")
check("цикл не Linear: предупреждение", len(lines(lin, "интерполяция не Linear")) == 1)

nor = build(with_radius=False)
check("нет radius: ошибка", len(lines(nor, "нет extras radius")) == 1, lines(nor, "radius"))

low = build(radius=1.2, pos_radius=0.9)
check("радиус не сходится с высотой оси: предупреждение", len(lines(low, "должен быть на Y")) >= 1, lines(low, "Y="))

print()
print("FAIL: %d" % len(fails) if fails else "Все проверки пройдены")
sys.exit(1 if fails else 0)
