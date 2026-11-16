#!/usr/bin/env python3
"""glb_preflight: проверка модели из Blender перед импортом в Godot (ATTN_24).

Запуск (из корня репозитория, Godot не нужен, только Python 3.8+):

    python tools/glb_preflight.py data/models/wagon_coal_01/wagon_coal_01.glb
    python tools/glb_preflight.py model.glb                                        # новая модель: Z=0 это ось буферов, offset_mesh_y = 1.061
    python tools/glb_preflight.py old.gltf --config data/trains/objects/wagon_03.tres --offset-y 1.15   # старая модель: её offset_mesh_y
    python tools/glb_preflight.py model.glb --brush      # нужна ли UV2 для кисти Library

Что делает: читает glb/gltf, ничего не меняет и не пишет. Печатает отчёт ERROR / WARN / INFO
и «заготовки» чисел для конфигов (MechanismConfig, LightConfig, коллизия кузова).
Код возврата 1, если есть хотя бы одна ERROR.

    python tools/glb_preflight.py data/models/room_test_01/room_test_01.glb --kind room   # комната (ATTN_25 §25.7), числа карточки RoomConfig

Правила, по которым идёт проверка, описаны в 0_ATTN_24_model_pipeline.md (§24.3 и §24.4); для комнат ATTN_25 §25.7.5 (код правил один на Blender и на этот файл:
tools/blender/ec_room_tools.py, функция check_room).
Координаты в отчёте уже в осях Godot (экспортёр glTF переводит Blender (x, y, z) в (x, z, -y)):
нос это -Z, вверх +Y, вправо по ходу +X.
"""
import argparse
import base64
import importlib.util
import json
import math
import os
import re
import struct
import sys

# Имена, которые Blender даёт новым объектам, и отладочные узлы проекта: в рабочей модели их быть не должно
DEFAULT_BLENDER_NAMES = re.compile(r"^(Cube|Plane|Sphere|Cylinder|Cone|Torus|Circle|Empty|Suzanne|Light|Camera)(\.\d+)?$", re.I)
DEBUG_NAMES = {"sphere", "frontmarker", "ax", "ay", "az", "marker"}
DUP_SUFFIX = re.compile(r"[.]\d{3,}$")
ROLE_RE = re.compile(r"^[a-z][a-z0-9_]*$")
# Префиксы материалов (см. ATTN_24 §24.4). Остальные материалы считаются «как есть», не красятся
MAT_PREFIXES = ("paint_", "trim_", "glass_", "emit_", "rubber_", "metal_")
ANCHOR_PREFIXES = ("anchor_", "light_", "lamp_", "headlight", "taillight", "cab_")
# NEM 303 «Puffer» (обязательная норма, издание 2015), H0: высота середины буфера над головкой рельса 12.2 ±0.5 мм,
# расстояние между осями буферов 20.0 ±0.2 мм, нижняя кромка тарелки не ниже 9.6 мм.
# В единицах игры (1 единица = 1 м прототипа, масштаб 1:87): 12.2 мм = 1.061, ±0.5 мм = ±0.043, 20.0 мм = 1.74, 9.6 мм = 0.835
BUFFER_H = 1.061
BUFFER_TOL = 0.043
BUFFER_SPACING = 1.74
BUFFER_SPACING_TOL = 0.035  # NEM даёт ±0.2 мм (0.017), берём вдвое шире: у прототипов шаг 1750 мм
BUFFER_UMIN = 0.835
TRI_BUDGET = {"wagon": 40000, "loco": 60000, "building": 30000}

COMP_FMT = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}
TYPE_N = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


class Report:
    def __init__(self):
        self.items = []

    def add(self, level, msg):
        self.items.append((level, msg))

    def count(self, level):
        return sum(1 for lv, _ in self.items if lv == level)


def load_gltf(path):
    """Возвращает (json, bin_bytes). Для .glb бинарный кусок берётся из файла, для .gltf из .bin или data URI"""
    raw = open(path, "rb").read()
    if raw[:4] == b"glTF":
        pos, js, binb = 12, None, b""
        while pos < len(raw):
            ln, kind = struct.unpack("<II", raw[pos:pos + 8])
            chunk = raw[pos + 8:pos + 8 + ln]
            if kind == 0x4E4F534A:
                js = json.loads(chunk.decode("utf-8"))
            elif kind == 0x004E4942:
                binb = chunk
            pos += 8 + ln + ((4 - ln % 4) % 4)
        return js, binb
    js = json.loads(raw.decode("utf-8"))
    binb = b""
    bufs = js.get("buffers", [])
    if bufs:
        uri = bufs[0].get("uri", "")
        if uri.startswith("data:"):
            binb = base64.b64decode(uri.split(",", 1)[1])
        elif uri:
            p = os.path.join(os.path.dirname(path), uri)
            if os.path.exists(p):
                binb = open(p, "rb").read()
    return js, binb


def read_accessor(g, binb, idx):
    """Читает accessor в список кортежей (без sparse). Для проверок хватает float и целых"""
    acc = g["accessors"][idx]
    n = TYPE_N[acc["type"]]
    fmt = COMP_FMT[acc["componentType"]]
    size = struct.calcsize(fmt)
    if "bufferView" not in acc:
        return [tuple([0] * n) for _ in range(acc["count"])]
    bv = g["bufferViews"][acc["bufferView"]]
    base = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    stride = bv.get("byteStride") or size * n
    out = []
    for i in range(acc["count"]):
        off = base + i * stride
        out.append(struct.unpack_from("<" + fmt * n, binb, off))
    return out


UV2_GRID = 256          # сетка занятости UV2 (как PaintBake.GROUP_GRID в Godot)
UV2_OVERLAP = 0.01      # допустимая доля ячеек меша, уже занятых другими мешами (PaintBake.GROUP_OVERLAP)
UV2_DENSITY_RATIO = 2.0  # во сколько раз плотность UV2 мешей группы может различаться без предупреждения


def read_uv2_mesh(g, binb, node_i):
    """UV2, позиции и индексы по поверхностям меша узла: [(uv2, pos, idx)]; None, если UV2 есть не везде"""
    out = []
    for pr in g["meshes"][g["nodes"][node_i]["mesh"]]["primitives"]:
        at = pr["attributes"]
        if "TEXCOORD_1" not in at:
            return None
        acc = g["accessors"][at["TEXCOORD_1"]]
        uv = read_accessor(g, binb, at["TEXCOORD_1"])
        if acc.get("normalized"):
            div = {5121: 255.0, 5123: 65535.0}.get(acc["componentType"], 1.0)
            uv = [(u / div, v / div) for u, v in uv]
        pos = read_accessor(g, binb, at["POSITION"])
        idx = [i[0] for i in read_accessor(g, binb, pr["indices"])] if "indices" in pr else list(range(len(pos)))
        out.append((uv, pos, idx))
    return out


def uv2_occupancy(surfs, grid=UV2_GRID):
    """Занятые ячейки UV2 (bytearray grid*grid) и сумма площадей UV2; тот же растр, что PaintBake.occupancy"""
    occ = bytearray(grid * grid)
    area = 0.0
    for uv, _pos, idx in surfs:
        for t in range(0, len(idx) - 2, 3):
            a, b, c = uv[idx[t]], uv[idx[t + 1]], uv[idx[t + 2]]
            d = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
            area += abs(d) / 2.0
            if abs(d) < 1e-14:
                continue
            x0 = min(max(int(math.floor(min(a[0], b[0], c[0]) * grid)), 0), grid - 1)
            x1 = min(max(int(math.ceil(max(a[0], b[0], c[0]) * grid)), 0), grid - 1)
            y0 = min(max(int(math.floor(min(a[1], b[1], c[1]) * grid)), 0), grid - 1)
            y1 = min(max(int(math.ceil(max(a[1], b[1], c[1]) * grid)), 0), grid - 1)
            for y in range(y0, y1 + 1):
                py = (y + 0.5) / grid
                for x in range(x0, x1 + 1):
                    px = (x + 0.5) / grid
                    w0 = ((b[1] - c[1]) * (px - c[0]) + (c[0] - b[0]) * (py - c[1])) / d
                    w1 = ((c[1] - a[1]) * (px - c[0]) + (a[0] - c[0]) * (py - c[1])) / d
                    if w0 < 0.0 or w1 < 0.0 or w0 + w1 > 1.0:
                        continue
                    occ[y * grid + x] = 1
    return occ, area


def world_area(surfs, scale):
    """Площадь поверхностей меша в мире (масштаб узла учитывается средним по осям)"""
    total = 0.0
    for _uv, pos, idx in surfs:
        for t in range(0, len(idx) - 2, 3):
            p0, p1, p2 = pos[idx[t]], pos[idx[t + 1]], pos[idx[t + 2]]
            ux, uy, uz = p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]
            vx, vy, vz = p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]
            cx, cy, cz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
            total += math.sqrt(cx * cx + cy * cy + cz * cz) / 2.0
    return total * scale * scale


def check_uv2_atlas(g, binb, nodes, rep, brush):
    """Общий атлас UV2 для кисти Library: меши кузова делят один лист без перекрытий и с одной плотностью.
    Группа собирается как в Godot (PaintBake.group): опорный меш самый крупный, остальные входят, пока не перекрывают занятое"""
    lvl = "WARN" if brush else "INFO"
    items = []
    for i, n in enumerate(nodes):
        if "mesh" not in n:
            continue
        surfs = read_uv2_mesh(g, binb, i)
        if not surfs:
            continue
        sc = n.get("scale") or (1, 1, 1)
        scale = abs(sc[0] * sc[1] * sc[2]) ** (1.0 / 3.0) or 1.0
        occ, uv_area = uv2_occupancy(surfs)
        wa = world_area(surfs, scale)
        lo_u = min(min(u for u, _ in s[0]) for s in surfs)
        hi_u = max(max(u for u, _ in s[0]) for s in surfs)
        lo_v = min(min(v for _, v in s[0]) for s in surfs)
        hi_v = max(max(v for _, v in s[0]) for s in surfs)
        if lo_u < -0.001 or lo_v < -0.001 or hi_u > 1.001 or hi_v > 1.001:
            rep.add(lvl, "Меш '%s': UV2 выходит за 0..1 (u %.2f..%.2f, v %.2f..%.2f): краска за границей листа теряется." % (node_name(g, i), lo_u, hi_u, lo_v, hi_v))
        items.append({
            "name": node_name(g, i), "occ": occ, "cnt": sum(occ), "verts": sum(len(s[1]) for s in surfs),
            "density": math.sqrt(uv_area / wa) * 1024.0 if wa > 1e-12 else 0.0, "world": wa,
        })
    if not items:
        return
    order = sorted(range(len(items)), key=lambda k: (-items[k]["verts"], k))
    seed = order[0]
    union = bytearray(UV2_GRID * UV2_GRID)
    group, skipped = [], []
    for k in order:
        it = items[k]
        over = sum(1 for j in range(len(it["occ"])) if it["occ"][j] and union[j])
        if k == seed or (it["cnt"] > 0 and over <= max(2, int(it["cnt"] * UV2_OVERLAP))):
            for j in range(len(it["occ"])):
                if it["occ"][j]:
                    union[j] = 1
            group.append(k)
        else:
            skipped.append((k, over))
    for k, over in skipped:
        it = items[k]
        rep.add(lvl, "Меш '%s': UV2 перекрывает атлас других мешей (%d%% его ячеек): кисть Library его не красит, мазок через него не проходит. "
                     "Blender: кнопка «UV2: общий атлас» (блок 2), затем экспорт заново." % (it["name"], round(100.0 * over / max(it["cnt"], 1))))
    dens = [items[k]["density"] for k in group if items[k]["density"] > 0.0]
    if len(dens) > 1 and max(dens) / min(dens) > UV2_DENSITY_RATIO:
        lo_k = min((k for k in group if items[k]["density"] > 0.0), key=lambda k: items[k]["density"])
        hi_k = max(group, key=lambda k: items[k]["density"])
        rep.add(lvl, "Плотность UV2 в общем атласе различается в %.1f раза: '%s' %.0f текс/м, '%s' %.0f текс/м (при листе 1024). "
                     "Кисть на густой детали будет резче, чем на редкой. Blender: «UV2: общий атлас» выравнивает масштаб островов." %
                     (max(dens) / min(dens), items[hi_k]["name"], items[hi_k]["density"], items[lo_k]["name"], items[lo_k]["density"]))
    filled = sum(union)
    world = sum(items[k]["world"] for k in group)
    mean = math.sqrt(max(filled, 1) / float(UV2_GRID * UV2_GRID) * 1024.0 * 1024.0 / max(world, 1e-9))
    rep.add("INFO", "Атлас UV2 для кисти: в общем листе %d из %d мешей, занято %.0f%% листа, около %.1f текселя/м при слое 1024 (тексель около %.1f см). "
                    "Опорный меш '%s'.%s" % (len(group), len(items), 100.0 * filled / (UV2_GRID * UV2_GRID), mean, 100.0 / mean if mean else 0.0,
                                              items[seed]["name"], (" Вне группы: %s." % ", ".join(items[k]["name"] for k, _ in skipped)) if skipped else ""))


def fmt3(v):
    return "(%.3f, %.3f, %.3f)" % (v[0], v[1], v[2])


def quat_to_axis_angle(q):
    x, y, z, w = q
    ln = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    x, y, z, w = x / ln, y / ln, z / ln, w / ln
    if w < 0:
        x, y, z, w = -x, -y, -z, -w
    s = math.sqrt(max(0.0, 1.0 - w * w))
    ang = 2.0 * math.acos(min(1.0, w))
    if s < 1e-6:
        return (0.0, 0.0, 0.0), 0.0
    return (x / s, y / s, z / s), math.degrees(ang)


def quat_mul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz)


def quat_inv(q):
    return (-q[0], -q[1], -q[2], q[3])


def node_name(g, i):
    return g["nodes"][i].get("name", "node_%d" % i)


# ---------------------------------------------------------------- комната (--kind room)

def _mat_identity():
    return [[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 1.0]]


def _mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def _node_matrix(n):
    """Локальная матрица узла glTF (TRS или matrix), строки: m[i][j]"""
    if "matrix" in n:
        v = n["matrix"]   # столбцы
        return [[v[c * 4 + r] for c in range(4)] for r in range(4)]
    t = n.get("translation") or (0.0, 0.0, 0.0)
    x, y, z, w = n.get("rotation") or (0.0, 0.0, 0.0, 1.0)
    s = n.get("scale") or (1.0, 1.0, 1.0)
    r = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
         [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
         [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
    return [[r[0][0] * s[0], r[0][1] * s[1], r[0][2] * s[2], t[0]],
            [r[1][0] * s[0], r[1][1] * s[1], r[1][2] * s[2], t[1]],
            [r[2][0] * s[0], r[2][1] * s[1], r[2][2] * s[2], t[2]],
            [0.0, 0.0, 0.0, 1.0]]


def _g2b(v):
    """Оси glTF (Godot) -> оси Blender: (x, y, z) -> (x, -z, y)"""
    return (v[0], -v[2], v[1])


def _image_size(g, binb, img):
    """Ширина и высота вшитой картинки (PNG или JPEG) по заголовку; None, если не удалось прочесть"""
    data = None
    if "bufferView" in img:
        bv = g["bufferViews"][img["bufferView"]]
        off = bv.get("byteOffset", 0)
        data = binb[off:off + bv["byteLength"]]
    elif str(img.get("uri", "")).startswith("data:"):
        data = base64.b64decode(img["uri"].split(",", 1)[1])
    if not data:
        return None
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        return struct.unpack(">II", data[16:24])
    if data[:2] == b"\xff\xd8":
        pos = 2
        while pos + 9 < len(data):
            if data[pos] != 0xFF:
                pos += 1
                continue
            marker = data[pos + 1]
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                pos += 2
                continue
            ln = struct.unpack(">H", data[pos + 2:pos + 4])[0]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">HH", data[pos + 5:pos + 9])
                return (w, h)
            pos += 2 + ln
    return None


def load_room_rules():
    """Правила комнаты лежат в tools/blender/ec_room_tools.py (один набор на Blender и на этот файл). Модуль, None если файла нет"""
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "blender", "ec_room_tools.py")
    if not os.path.exists(path):
        return None
    spec = importlib.util.spec_from_file_location("ec_room_tools", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def room_snapshot(g, binb, fps=24.0):
    """Снимок сцены для check_room из готового .glb. Оси и метры как в Blender (+Y север), см. ec_room_tools.check_room"""
    nodes = g.get("nodes", [])
    parent = {}
    for i, n in enumerate(nodes):
        for c in n.get("children", []):
            parent[c] = i
    counts = {}
    for n in nodes:
        counts[n.get("name", "")] = counts.get(n.get("name", ""), 0) + 1
    ids = [(n.get("name", "node_%d" % i) if counts.get(n.get("name", ""), 0) == 1 else "%s#%d" % (n.get("name", "node_%d" % i), i)) for i, n in enumerate(nodes)]
    world = {}

    def wmat(i):
        if i not in world:
            m = _node_matrix(nodes[i])
            world[i] = _mat_mul(wmat(parent[i]), m) if i in parent else m
        return world[i]

    out = []
    materials = {}
    for m in g.get("materials", []):
        materials[m.get("name", "?")] = {"transparent": m.get("alphaMode", "OPAQUE") != "OPAQUE"}
    for i, n in enumerate(nodes):
        ex = n.get("extras") if isinstance(n.get("extras"), dict) else {}
        kind = "CAMERA" if "camera" in n else ("LIGHT" if "KHR_lights_punctual" in (n.get("extensions") or {}) else ("MESH" if "mesh" in n else "EMPTY"))
        w = wmat(i)
        rot = n.get("rotation")
        ang = 0.0
        if rot:
            ang = quat_to_axis_angle(rot)[1]
        scale = tuple(n.get("scale") or (1.0, 1.0, 1.0))
        d = {"id": ids[i], "name": n.get("name", "node_%d" % i), "parent": ids[parent[i]] if i in parent else None, "kind": kind, "props": dict(ex),
             "data_role": False, "pos": _g2b((w[0][3], w[1][3], w[2][3])), "scale": scale, "rot_deg": ang, "aim": None, "bbox": None, "tris": 0, "mats": []}
        ay = (w[0][1], w[1][1], w[2][1])   # локальная +Y glTF = стрелка пустышки (+Z Blender)
        ln = math.sqrt(sum(c * c for c in ay)) or 1.0
        d["aim"] = _g2b(tuple(c / ln for c in ay))
        if "mesh" in n:
            lo, hi = [1e9] * 3, [-1e9] * 3
            mats = []
            for pr in g["meshes"][n["mesh"]]["primitives"]:
                at = pr["attributes"]
                cnt = g["accessors"][pr["indices"]]["count"] if "indices" in pr else g["accessors"][at["POSITION"]]["count"]
                d["tris"] += cnt // 3
                pos = g["accessors"][at["POSITION"]]
                if "min" in pos:
                    for k in range(3):
                        lo[k] = min(lo[k], pos["min"][k])
                        hi[k] = max(hi[k], pos["max"][k])
                if "material" in pr:
                    nm = g["materials"][pr["material"]].get("name", "?")
                    if nm not in mats:
                        mats.append(nm)
            d["mats"] = mats
            if lo[0] < 1e8:
                pts = []
                for cx in (lo[0], hi[0]):
                    for cy in (lo[1], hi[1]):
                        for cz in (lo[2], hi[2]):
                            pts.append(_g2b((w[0][0] * cx + w[0][1] * cy + w[0][2] * cz + w[0][3],
                                             w[1][0] * cx + w[1][1] * cy + w[1][2] * cz + w[1][3],
                                             w[2][0] * cx + w[2][1] * cy + w[2][2] * cz + w[2][3])))
                d["bbox"] = (tuple(min(p[k] for p in pts) for k in range(3)), tuple(max(p[k] for p in pts) for k in range(3)))
        out.append(d)
    images = []
    for k, im in enumerate(g.get("images", [])):
        sz = _image_size(g, binb, im)
        if sz:
            images.append({"name": im.get("name", "image_%d" % k), "w": sz[0], "h": sz[1]})
    actions = []
    for a in g.get("animations", []):
        info = {"name": a.get("name", "?"), "targets": [], "kinds": [], "scale_moved": False, "nonlinear": False, "frames": None, "stub": None}
        for ch in a.get("channels", []):
            tgt = ch["target"]
            if "node" not in tgt:
                continue
            smp = a["samplers"][ch["sampler"]]
            times = [t[0] for t in read_accessor(g, binb, smp["input"])]
            vals = read_accessor(g, binb, smp["output"])
            if not times or not vals:
                continue
            tid = ids[tgt["node"]]
            if tid not in info["targets"]:
                info["targets"].append(tid)
            if smp.get("interpolation", "LINEAR") != "LINEAR":
                info["nonlinear"] = True
            path = tgt["path"]
            if path == "translation":
                dv = tuple(vals[-1][k] - vals[0][k] for k in range(3))
                ln = math.sqrt(sum(c * c for c in dv))
                if ln > 1e-5:
                    info["kinds"].append("move")
                    info["stub"] = {"kind": "move", "axis": tuple(c / ln for c in dv), "travel": ln * 100.0, "duration": times[-1] - times[0]}
            elif path == "rotation":
                ax, ang = quat_to_axis_angle(quat_mul(vals[-1], quat_inv(vals[0])))
                if ang > 0.01:
                    info["kinds"].append("rot")
                    info["stub"] = {"kind": "rot", "axis": ax, "travel": ang, "duration": times[-1] - times[0]}
            elif path == "scale":
                if max(abs(vals[-1][k] - vals[0][k]) for k in range(3)) > 1e-5:
                    info["scale_moved"] = True
        info["kinds"] = sorted(set(info["kinds"]))
        if len(info["kinds"]) != 1:
            info["stub"] = None
        actions.append(info)
    return {"nodes": out, "materials": materials, "images": images, "actions": actions, "strays": [],
            "extras_present": any(isinstance(n.get("extras"), dict) and n["extras"] for n in nodes)}


def run_room(path):
    """glb_preflight --kind room: правила комнаты на готовом файле, печать отчёта. Код возврата 1 при ERROR"""
    rules = load_room_rules()
    if rules is None:
        print("[ERROR] Не найден tools/blender/ec_room_tools.py: правила комнаты лежат в нём.")
        return 1
    g, binb = load_gltf(path)
    snap = room_snapshot(g, binb)
    items = [(lv, tx) for lv, tx, _ in rules.check_room(snap)]
    # проверки, которые видны только в файле
    used = g.get("extensionsUsed") or []
    if g.get("cameras"):
        items.append(("ERROR", "В файле есть камеры (%d): при экспорте Include, Cameras выключить." % len(g["cameras"])))
    if "KHR_lights_punctual" in used:
        items.append(("ERROR", "В файле есть источники света (KHR_lights_punctual): при экспорте Include, Punctual Lights выключить, свет задаётся якорями role = light."))
    if "KHR_draco_mesh_compression" in used:
        items.append(("ERROR", "Сжатие Draco: Godot такой файл не читает, выключите Compression при экспорте."))
    if g.get("skins"):
        items.append(("WARN", "Есть скины (%d): механизмы комнаты двигают узлы, а не кости." % len(g["skins"])))
    scenes = g.get("scenes", [])
    roots = scenes[g.get("scene", 0)].get("nodes", []) if scenes else []
    if len(roots) != 1:
        items.append(("ERROR", "В сцене %d корневых узлов, нужен ровно один (Room, role = room)." % len(roots)))
    nodes = g.get("nodes", [])
    tris = sum(n["tris"] for n in snap["nodes"])
    print("Комната: %s" % path)
    print("Узлов: %d, мешей: %d, материалов: %d, текстур: %d, треугольников (с прокси): %d, анимаций: %d" %
          (len(nodes), len([n for n in nodes if "mesh" in n]), len(g.get("materials", [])), len(g.get("images", [])), tris, len(g.get("animations", []))))
    roles = {}
    for n in snap["nodes"]:
        r = n["props"].get("role")
        if isinstance(r, str):
            roles.setdefault(r, []).append(n["name"])
    if roles:
        print("Роли: " + ", ".join("%s (%s)" % (r, ", ".join(v)) for r, v in sorted(roles.items())))
    print()
    order = {"ERROR": 0, "WARN": 1, "INFO": 2}
    for lvl, msg in sorted(items, key=lambda x: order[x[0]]):
        print("[%s] %s" % (lvl, msg))
    print()
    e = sum(1 for lv, _ in items if lv == "ERROR")
    print("Итог: ERROR %d, WARN %d, INFO %d" % (e, sum(1 for lv, _ in items if lv == "WARN"), sum(1 for lv, _ in items if lv == "INFO")))
    return 1 if e else 0


def main():
    ap = argparse.ArgumentParser(description="Предполётная проверка glb/gltf для Godot (ATTN_24)")
    ap.add_argument("model", help="путь к .glb или .gltf")
    ap.add_argument("--kind", choices=["wagon", "loco", "building", "room"], default="wagon", help="тип модели (бюджет треугольников); room: комната, правила ATTN_25 §25.7.5")
    ap.add_argument("--config", help="EntitySetting .tres: проверить, что роли из part_role и anchor_role есть в модели")
    ap.add_argument("--offset-y", type=float, default=None, help="WagonConfig.offset_mesh_y: высота начала кузова над головкой рельса. "
                                                                  "Не задан: берётся стандартная высота буферов (--buffer-h), как у новой модели")
    ap.add_argument("--buffer-h", type=float, default=BUFFER_H, help="стандартная высота оси буферов над головкой рельса, единицы игры (по умолчанию %.3f)" % BUFFER_H)
    ap.add_argument("--tol", type=float, default=BUFFER_TOL, help="допуск высоты буферов, единицы игры (по умолчанию %.3f)" % BUFFER_TOL)
    ap.add_argument("--brush", action="store_true", help="модель нужна для кисти Library: UV2 обязательна (иначе только предупреждение)")
    args = ap.parse_args()
    if args.kind == "room":
        return run_room(args.model)

    rep = Report()
    offset_given = args.offset_y is not None
    abs_y = args.offset_y if offset_given else args.buffer_h  # высота начала кузова над головкой рельса в игре
    g, binb = load_gltf(args.model)
    nodes = g.get("nodes", [])
    parent = {}
    for i, n in enumerate(nodes):
        for c in n.get("children", []):
            parent[c] = i

    def role_of(i):
        ex = nodes[i].get("extras")
        if isinstance(ex, dict) and "role" in ex:
            return str(ex["role"])
        return None

    def ancestors(i):
        out = []
        while i in parent:
            i = parent[i]
            out.append(i)
        return out

    # ---- Сцена и корень ----
    scenes = g.get("scenes", [])
    roots = scenes[g.get("scene", 0)].get("nodes", []) if scenes else []
    if len(roots) != 1:
        rep.add("ERROR", "В сцене %d корневых узлов, нужен ровно один (кузов, role=body). Всё остальное его дети." % len(roots))
    body = None
    bodies = [i for i in range(len(nodes)) if role_of(i) == "body"]
    if len(bodies) != 1:
        rep.add("ERROR", "Узлов с role=body: %d, нужен ровно один." % len(bodies))
    else:
        body = bodies[0]
        if roots and roots[0] != body:
            rep.add("ERROR", "role=body стоит не на корневом узле (корень: '%s')." % node_name(g, roots[0]))
        if "mesh" not in nodes[body]:
            rep.add("ERROR", "У узла body нет меша: кузов должен быть мешем.")

    # ---- Роли ----
    roles = {}
    for i in range(len(nodes)):
        r = role_of(i)
        if r is None:
            continue
        if not ROLE_RE.match(r):
            rep.add("ERROR", "Роль '%s' (узел '%s'): только a-z, 0-9, _, начинается с буквы." % (r, node_name(g, i)))
        roles.setdefault(r, []).append(i)
    for r, lst in roles.items():
        if len(lst) > 1:
            rep.add("WARN", "Роль '%s' у %d узлов (%s): PartRegistry возьмёт первый. Для пар используйте _l/_r, _1/_2." %
                    (r, len(lst), ", ".join(node_name(g, i) for i in lst)))

    if nodes and not roles:
        rep.add("INFO", "Ни у одного узла нет extras (ролей). Если роли в Blender назначены, в экспорте не включено Include, Custom Properties "
                        "(панель EC включает сама); роль должна стоять на объекте, не на данных меша.")

    # ---- Имена узлов ----
    for i, n in enumerate(nodes):
        nm = n.get("name", "")
        if DUP_SUFFIX.search(nm):
            rep.add("WARN", "Узел '%s': хвост дубля (.001). Id зоны покраски строится из имени узла, при переименовании покраска исполнений потеряется." % nm)
        if " " in nm:
            rep.add("WARN", "Узел '%s': пробел в имени, используйте _." % nm)
        if DEFAULT_BLENDER_NAMES.match(nm):
            rep.add("WARN", "Узел '%s': имя по умолчанию из Blender, дайте осмысленное." % nm)
        if nm.lower() in DEBUG_NAMES:
            rep.add("WARN", "Узел '%s': отладочный, в рабочую модель не экспортируем." % nm)
        if re.search(r"[A-Za-z]", nm) and re.search(r"[\u0400-\u04FF]", nm):
            rep.add("WARN", "Узел '%s': латиница вместе с кириллицей (похожие буквы, например кириллическая «С» вместо латинской «C»). "
                            "По имени узла строятся зоны покраски и слои кисти: найти такой узел по имени в Blender трудно. Переименуйте латиницей "
                            "(покраска зон сохранённых исполнений этого узла сбросится)." % nm)

    # ---- Меши вне кузова ----
    for i, n in enumerate(nodes):
        if "mesh" in n and body is not None and i != body and body not in ancestors(i):
            rep.add("ERROR", "Меш '%s' не потомок кузова: он не поднимется вместе с кузовом (offset_mesh_y)." % node_name(g, i))

    # ---- Трансформы ----
    for i, n in enumerate(nodes):
        nm = node_name(g, i)
        if "matrix" in n:
            rep.add("WARN", "Узел '%s': трансформ задан матрицей. Проверьте Apply Transforms." % nm)
        sc = n.get("scale")
        if sc and any(abs(s - 1.0) > 1e-4 for s in sc):
            rep.add("ERROR", "Узел '%s': масштаб %s. Сделайте Apply Scale (Ctrl+A), иначе оси механизмов и свет поедут." % (nm, fmt3(sc)))
        rot = n.get("rotation")
        if rot and any(abs(c) > 1e-4 for c in rot[:3]):
            lvl = "ERROR" if i == body else "WARN"
            rep.add(lvl, "Узел '%s': поворот в покое. Для оси механизма и кузова нужен Apply Rotation, положение покоя без поворота." % nm)
    if body is not None:
        t = nodes[body].get("translation")
        if t and any(abs(c) > 1e-4 for c in t):
            rep.add("WARN", "Корень body смещён %s: нулевая точка модели должна быть в начале координат." % fmt3(t))

    # ---- Меши, материалы, UV, треугольники ----
    mats_used = {}
    tris_total = 0
    uv2_missing = 0
    prims_total = 0
    bbox = None  # в локальных координатах корня (корень без трансформа)
    part_bbox = {}

    def world_translation(i):
        x = y = z = 0.0
        j = i
        while j is not None:
            t = nodes[j].get("translation") or (0, 0, 0)
            x += t[0]
            y += t[1]
            z += t[2]
            j = parent.get(j)
        return (x, y, z)

    for i, n in enumerate(nodes):
        if "mesh" not in n:
            continue
        mesh = g["meshes"][n["mesh"]]
        origin = world_translation(i)
        lo = [1e9] * 3
        hi = [-1e9] * 3
        for pr in mesh["primitives"]:
            prims_total += 1
            at = pr["attributes"]
            if "TEXCOORD_0" not in at:
                rep.add("WARN", "Меш '%s': нет UV0. Покраска плоским цветом работает, текстуры нет." % node_name(g, i))
            if "TEXCOORD_1" not in at:
                uv2_missing += 1
            if "NORMAL" not in at:
                rep.add("WARN", "Меш '%s': нет нормалей." % node_name(g, i))
            if "indices" in pr:
                tris_total += g["accessors"][pr["indices"]]["count"] // 3
            else:
                tris_total += g["accessors"][at["POSITION"]]["count"] // 3
            pos = g["accessors"][at["POSITION"]]
            if "min" in pos:
                for k in range(3):
                    lo[k] = min(lo[k], pos["min"][k])
                    hi[k] = max(hi[k], pos["max"][k])
            if "material" in pr:
                m = g["materials"][pr["material"]]
                mats_used.setdefault(m.get("name", "?"), m)
            else:
                rep.add("WARN", "Меш '%s': поверхность без материала." % node_name(g, i))
        if lo[0] < 1e8:
            part_bbox[i] = (lo, hi)
            w_lo = [lo[k] + origin[k] for k in range(3)]
            w_hi = [hi[k] + origin[k] for k in range(3)]
            bbox = (w_lo, w_hi) if bbox is None else ([min(bbox[0][k], w_lo[k]) for k in range(3)],
                                                       [max(bbox[1][k], w_hi[k]) for k in range(3)])

    budget = TRI_BUDGET[args.kind]
    if tris_total > budget:
        rep.add("WARN", "Треугольников %d, бюджет для %s около %d. Уберите невидимое, упростите фаски." % (tris_total, args.kind, budget))
    if uv2_missing:
        lvl = "WARN" if args.brush else "INFO"
        rep.add(lvl, "UV2 (TEXCOORD_1) нет у %d из %d поверхностей. Кисть Library нужна неперекрывающаяся UV2 (Blender: вторая UV-карта "
                     "или import «Static Lightmaps»). Покраска по зонам работает и без неё." % (uv2_missing, prims_total))

    if not uv2_missing and prims_total:
        check_uv2_atlas(g, binb, nodes, rep, args.brush)

    # ---- Материалы ----
    paint_mats = [m for m in mats_used if m.lower().startswith("paint_")]
    for name, m in mats_used.items():
        if DUP_SUFFIX.search(name):
            rep.add("WARN", "Материал '%s': хвост дубля (.001). Переименуйте или слейте материалы." % name)
        alpha = m.get("alphaMode", "OPAQUE")
        if alpha != "OPAQUE" and not name.lower().startswith(("glass_", "emit_")):
            rep.add("WARN", "Материал '%s' прозрачный (%s), но имя не glass_*/emit_*: «Весь корпус» его не отличит от красимого." % (name, alpha))
        ex = m.get("extensions", {})
        if "KHR_materials_clearcoat" in ex:
            rep.add("INFO", "Материал '%s': clearcoat поддерживается Godot, но на мобильных и в Compatibility дороже. Глянец можно задать finish." % name)
    if mats_used and not paint_mats:
        rep.add("WARN", "Нет материалов paint_*. Покраска зоной «Весь корпус» зальёт ВСЕ непрозрачные поверхности (сталь, резину, днище). "
                        "Назовите красимые материалы paint_body, paint_roof и т.д.")
    unnamed = [k for k in mats_used if not k.lower().startswith(MAT_PREFIXES)]
    if paint_mats and unnamed:
        rep.add("INFO", "Материалы без префикса (красить не планируется): %s" % ", ".join(sorted(unnamed)))

    # ---- Лишнее в файле ----
    if g.get("cameras"):
        rep.add("WARN", "В файле есть камеры (%d): в Blender снимите при экспорте." % len(g["cameras"]))
    if "KHR_lights_punctual" in (g.get("extensionsUsed") or []):
        rep.add("WARN", "В файле есть источники света (KHR_lights_punctual). Свет задаётся LightConfig, в Blender не экспортируйте (Include: Punctual Lights выкл).")
    if g.get("skins"):
        rep.add("INFO", "Есть скины (%d): механизмы проекта двигают узлы, а не кости. Для дышл и пантографов делайте отдельные узлы." % len(g["skins"]))

    # ---- Габариты ----
    if bbox:
        lo, hi = bbox
        length, width, height = hi[2] - lo[2], hi[0] - lo[0], hi[1] - lo[1]
        cx, cz = (hi[0] + lo[0]) / 2.0, (hi[2] + lo[2]) / 2.0
        rep.add("INFO", "Габарит по осям Godot: длина (Z) %.3f, ширина (X) %.3f, высота (Y) %.3f; min Y %.3f, max Y %.3f." % (length, width, height, lo[1], hi[1]))
        rep.add("INFO", "Для паспорта: coupler_offset около %.2f (половина длины), ширина кузова %.2f." % (length / 2.0, width))
        bottom = lo[1] + abs_y
        if bottom < -0.01:
            rep.add("WARN", "Низ модели на %.3f ниже головки рельса (min Y %.3f, высота начала кузова %.3f). Проверьте метку Z=0 (ось буферов) и offset_mesh_y." %
                    (-bottom, lo[1], abs_y))
        rep.add("INFO", "Высота начала кузова над рельсом %.3f (%s), низ модели на высоте %.3f над рельсом, верх на %.3f." %
                (abs_y, "offset_mesh_y из --offset-y" if offset_given else "стандартная высота буферов, новая модель", bottom, hi[1] + abs_y))
        if not offset_given:
            rep.add("INFO", "Новая модель: в паспорте offset_mesh_y = %.3f. Колесо с радиусом r поднимает верх до 2r над рельсом, то есть на 2r - %.3f относительно метки Z=0: "
                            "колёса большого диаметра должны помещаться в вырезы кузова." % (args.buffer_h, args.buffer_h))
        if abs(cx) > 0.05 or abs(cz) > 0.05:
            rep.add("WARN", "Центр габарита смещён от нулевой точки: X %.3f, Z %.3f. Сделайте origin кузова центром по длине и ширине." % (cx, cz))
        rep.add("INFO", "Коллизия кузова (BoxShape3D, до подъёма кузова на его высоту): size = (%.3f, %.3f, %.3f), position = (%.3f, %.3f, %.3f)." %
                (width, height, length, cx, (hi[1] + lo[1]) / 2.0, cz))
        if args.kind in ("wagon", "loco") and width > 4.5:
            rep.add("WARN", "Ширина %.2f: для подвижного состава HO это много (проверьте масштаб: 1 единица Blender = 1 м прототипа)." % width)
        if length < 3.0 or length > 40.0:
            rep.add("WARN", "Длина %.2f вне ожидаемых 3..40 единиц: проверьте масштаб (Unit Scale 1.0, Apply Scale)." % length)

    # ---- Шарниры (origin) у подвижных частей ----
    for r, lst in roles.items():
        for i in lst:
            if i == body or i not in part_bbox:
                continue
            lo, hi = part_bbox[i]
            size = [hi[k] - lo[k] for k in range(3)]
            rel = []
            for k, ax in enumerate("XYZ"):
                if size[k] < 1e-6:
                    continue
                f = (0.0 - lo[k]) / size[k]
                if f < -0.01 or f > 1.01:
                    rel.append("%s: origin снаружи меша" % ax)
                elif f < 0.05 or f > 0.95:
                    rel.append("%s: на краю" % ax)
                elif 0.45 <= f <= 0.55:
                    rel.append("%s: в центре" % ax)
                else:
                    rel.append("%s: %.0f%%" % (ax, f * 100))
            rep.add("INFO", "Часть '%s' (role=%s): origin относительно её габарита: %s. Для ROTATE origin должен лежать на оси вращения (петля), "
                            "для SLIDE положение не важно, но одинаково у парных частей." % (node_name(g, i), r, "; ".join(rel)))

    # ---- Анимации -> заготовки MechanismConfig ----
    anims = g.get("animations", [])
    if not anims:
        rep.add("INFO", "Анимаций в файле нет. Механизмы описываются в MechanismConfig вручную (axis, travel, duration).")
    for a in anims:
        aname = a.get("name", "?")
        if not aname.startswith("mech_"):
            rep.add("WARN", "Анимация '%s': имя не mech_<id>. Для механизмов принято mech_door_left и т.п." % aname)
        by_node = {}
        for ch in a.get("channels", []):
            tgt = ch["target"]
            if "node" not in tgt:
                continue
            by_node.setdefault(tgt["node"], {})[tgt["path"]] = ch
        for ni, chans in by_node.items():
            nm = node_name(g, ni)
            if "scale" in chans:
                rep.add("WARN", "Анимация '%s', узел '%s': анимация масштаба не поддерживается механизмами." % (aname, nm))
            if "weights" in chans:
                rep.add("WARN", "Анимация '%s', узел '%s': morph targets не поддерживаются." % (aname, nm))
            part_role = role_of(ni)
            if part_role is None:
                rep.add("ERROR", "Анимация '%s' двигает узел '%s' без role: код найдёт часть только по роли." % (aname, nm))
            tr = chans.get("translation")
            ro = chans.get("rotation")
            dur = 0.0
            actuator, axis, travel = None, None, None
            if tr:
                smp = a["samplers"][tr["sampler"]]
                times = [t[0] for t in read_accessor(g, binb, smp["input"])]
                vals = read_accessor(g, binb, smp["output"])
                d = tuple(vals[-1][k] - vals[0][k] for k in range(3))
                L = math.sqrt(sum(c * c for c in d))
                dur = max(dur, times[-1] - times[0])
                if L > 1e-5:
                    actuator, axis, travel = "SLIDE", tuple(c / L for c in d), L
                    if smp.get("interpolation", "LINEAR") != "LINEAR":
                        rep.add("WARN", "Анимация '%s', '%s': сдвиг с интерполяцией %s, механизм идёт плавно сам (smoothstep), в Blender ставьте Linear." % (aname, nm, smp["interpolation"]))
            if ro:
                smp = a["samplers"][ro["sampler"]]
                times = [t[0] for t in read_accessor(g, binb, smp["input"])]
                vals = read_accessor(g, binb, smp["output"])
                dq = quat_mul(vals[-1], quat_inv(vals[0]))
                ax, ang = quat_to_axis_angle(dq)
                dur = max(dur, times[-1] - times[0])
                if ang > 0.01:
                    if smp.get("interpolation", "LINEAR") != "LINEAR":
                        rep.add("WARN", "Анимация '%s', '%s': поворот с интерполяцией %s, механизм идёт плавно сам (smoothstep), в Blender ставьте Linear." % (aname, nm, smp["interpolation"]))
                    if actuator == "SLIDE":
                        rep.add("WARN", "Анимация '%s', '%s': и сдвиг, и поворот. Один механизм это одно движение: разделите на два узла." % (aname, nm))
                    actuator, axis, travel = "ROTATE", ax, ang
            if actuator:
                rep.add("INFO", "Заготовка MechanismConfig из анимации '%s': part_role = &\"%s\", actuator = %s, axis = Vector3%s, travel = %.3f%s, duration = %.2f. "
                                "Ось дана в локальных осях родителя узла (у дочерних частей кузова это оси кузова)." %
                        (aname, part_role or "<role не задана, узел '%s'>" % nm, actuator, fmt3(axis), travel, " (градусы)" if actuator == "ROTATE" else "", dur))
            else:
                rep.add("WARN", "Анимация '%s', узел '%s': движения между первым и последним ключом нет." % (aname, nm))

    # ---- Буферы (NEM 303): ось на метке Z=0, на стандартной высоте, шаг, нижняя кромка ----
    buf_nodes = [i for i in range(len(nodes)) if (role_of(i) or "").startswith("buffer")]
    if buf_nodes:
        pts = []  # (x, y, z) центра буфера в осях glTF
        for i in buf_nodes:
            wt = world_translation(i)
            if i in part_bbox:
                lo_, hi_ = part_bbox[i]
                pts.append(((lo_[0] + hi_[0]) / 2.0 + wt[0], (lo_[1] + hi_[1]) / 2.0 + wt[1], (lo_[2] + hi_[2]) / 2.0 + wt[2]))
            else:
                pts.append(wt)
        ys = [p_[1] for p_ in pts]
        mean_y = sum(ys) / len(ys)
        height = mean_y + abs_y
        rep.add("INFO", "Буферы (%d узл.): ось на Z=%.3f относительно метки, в игре на высоте %.3f над рельсом (NEM 303: %.3f ±%.3f)." %
                (len(buf_nodes), mean_y, height, args.buffer_h, args.tol))
        if abs(height - args.buffer_h) > args.tol:
            rep.add("WARN", "Высота буферов %.3f вне допуска NEM 303 (%.3f ±%.3f): вагон встанет буферами выше или ниже остальных. "
                            "Ось буферов должна быть на Z=0 (offset_mesh_y %.3f)." % (height, args.buffer_h, args.tol, abs_y))
        if max(ys) - min(ys) > args.tol:
            rep.add("WARN", "Оси буферов разной высоты (разброс %.3f)." % (max(ys) - min(ys)))
        ends = {}
        for x_, y_, z_ in pts:
            ends.setdefault(z_ > 0, []).append(x_)
        for pos, xs in ends.items():
            if len(xs) == 2:
                spacing = abs(xs[0] - xs[1])
                rep.add("INFO", "Буферы %s торца: шаг осей %.3f (NEM 303: %.2f)." % ("заднего (+Z)" if pos else "переднего (-Z)", spacing, BUFFER_SPACING))
                if abs(spacing - BUFFER_SPACING) > BUFFER_SPACING_TOL:
                    rep.add("WARN", "Шаг осей буферов %.3f вне ожидаемых %.2f ±%.3f (NEM 303: 20.0 ±0.2 мм в H0, прототип 1750 мм)." % (spacing, BUFFER_SPACING, BUFFER_SPACING_TOL))
        for i in buf_nodes:
            if i in part_bbox:
                low = world_translation(i)[1] + part_bbox[i][0][1] + abs_y
                if low < BUFFER_UMIN - 0.01:
                    rep.add("WARN", "Буфер '%s': нижняя кромка на %.3f над рельсом, NEM 303 требует не ниже %.3f (место для сцепки, уходящей под буферами)." %
                            (node_name(g, i), low, BUFFER_UMIN))
    else:
        rep.add("INFO", "Узлов с ролью buffer* нет: высоту буферов автоматически проверить нельзя. Для проверки задайте роли buffer_1...buffer_4 мешам или пустышкам на осях буферов.")

    # ---- Якоря света ----
    anchors = [i for i in range(len(nodes)) if (role_of(i) or "").startswith(ANCHOR_PREFIXES)]
    for i in anchors:
        w = world_translation(i)
        lifted = (w[0], w[1] + abs_y, w[2])
        rot = nodes[i].get("rotation")
        rtxt = ""
        if rot:
            # Для SpotLight3D светит вдоль -Z. Печатаем Эйлера YXZ в градусах
            x, y, z, w_ = rot
            sinp = 2 * (w_ * x - y * z)
            ex = math.degrees(math.asin(max(-1.0, min(1.0, sinp))))
            ey = math.degrees(math.atan2(2 * (w_ * y + x * z), 1 - 2 * (x * x + y * y)))
            ez = math.degrees(math.atan2(2 * (w_ * z + x * y), 1 - 2 * (x * x + z * z)))
            rtxt = ", rotation_deg = Vector3(%.1f, %.1f, %.1f)" % (ex, ey, ez)
        rep.add("INFO", "Якорь '%s' (role=%s): LightConfig.position = Vector3%s%s (в системе корня сцены, высота кузова %.3f учтена). "
                        "В конфиг переносим числа, сам узел в игре не нужен." % (node_name(g, i), role_of(i), fmt3(lifted), rtxt, abs_y))

    # ---- Сверка с конфигом ----
    if args.config:
        try:
            txt = open(args.config, encoding="utf-8").read()
        except OSError as e:
            txt = ""
            rep.add("ERROR", "Не удалось прочитать конфиг: %s" % e)
        wanted = set(re.findall(r'(?:part_role|anchor_role)\s*=\s*&"([^"]+)"', txt))
        for w in sorted(wanted):
            key = re.sub(r"[^a-z0-9]", "", w.lower())
            have = {re.sub(r"[^a-z0-9]", "", r.lower()) for r in roles}
            if key not in have:
                rep.add("ERROR", "Конфиг %s ссылается на роль '%s', в модели такой роли нет (PartRegistry найдёт только по имени узла)." %
                        (os.path.basename(args.config), w))
        for r in sorted(roles):
            if r == "body" or r.startswith(ANCHOR_PREFIXES):
                continue
            if r not in wanted:
                rep.add("INFO", "Роль '%s' есть в модели, но конфиг её не использует (механизма или детали пока нет)." % r)

    # ---- Печать ----
    print("Модель: %s" % args.model)
    print("Узлов: %d, мешей: %d, поверхностей: %d, треугольников: %d, материалов: %d, анимаций: %d" %
          (len(nodes), len([n for n in nodes if "mesh" in n]), prims_total, tris_total, len(mats_used), len(anims)))
    if roles:
        print("Роли: " + ", ".join("%s (%s)" % (r, ", ".join(node_name(g, i) for i in lst)) for r, lst in sorted(roles.items())))
    print()
    order = {"ERROR": 0, "WARN": 1, "INFO": 2}
    for lvl, msg in sorted(rep.items, key=lambda x: order[x[0]]):
        print("[%s] %s" % (lvl, msg))
    print()
    print("Итог: ERROR %d, WARN %d, INFO %d" % (rep.count("ERROR"), rep.count("WARN"), rep.count("INFO")))
    return 1 if rep.count("ERROR") else 0


if __name__ == "__main__":
    sys.exit(main())
