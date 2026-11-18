#!/usr/bin/env python3
"""Заготовка детской для Blender-пайплайна (ATTN_25 RM9): .glb по геометрии процедурной детской kid_room_10 (core/room/room_decor.gd и
room_builder.gd), с ролями §25.7.2. Файл собран без Blender: из него автор берёт готовые группы, коллайдеры, прокси и размеры и
дорабатывает модель в Blender (или заменяет детали). Длины в сантиметрах, оси как в Godot (север -Z), пол на y = -50, стол на y = 0.

Материалы по ролям (6 штук + колба, небо, ложный AO): цвет детали лежит в вершинных цветах (COLOR_0, линейные), поэтому материалов мало.
Варианты стен, постели, штор и постеров процедурной детской здесь зафиксированы по умолчанию (dusty, red, yellow, trains).

    python tools/kid_room_gen.py data/models/room_kid_room_10_scene/room_kid_room_10_scene.glb
"""
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import room_fixture as fx   # noqa: E402

PALETTE = {
    "white": (0.95, 0.95, 0.93), "cream": (0.96, 0.90, 0.78), "wood_light": (0.86, 0.68, 0.45), "wood_dark": (0.55, 0.38, 0.24),
    "grey": (0.62, 0.64, 0.68), "dark": (0.18, 0.19, 0.22), "red": (0.90, 0.22, 0.20), "orange": (0.97, 0.58, 0.18),
    "yellow": (0.99, 0.82, 0.20), "green": (0.30, 0.70, 0.35), "blue": (0.22, 0.46, 0.88), "sky": (0.55, 0.78, 0.96),
    "purple": (0.58, 0.40, 0.80), "brown": (0.50, 0.33, 0.22), "dusty": (0.52, 0.64, 0.82), "slate": (0.42, 0.54, 0.72),
}
FLOOR_COLOR = (0.74, 0.58, 0.40)
CEILING_COLOR = (0.90, 0.90, 0.88)
FRAME_COLOR = (0.93, 0.93, 0.90)

# роль материала: имя в .glb, шероховатость, металличность
ROLES = {
    "paint": ("paint_kid", 0.8, 0.0), "wood": ("wood_kid", 0.75, 0.0), "fabric": ("fabric_kid", 0.95, 0.0),
    "metal": ("metal_kid", 0.35, 0.7), "plastic": ("plastic_kid", 0.4, 0.0), "paper": ("paper_kid", 0.9, 0.0),
}

SIZE = (480.0, 250.0, 380.0)   # внутренний объём комнаты, см
T = 10.0                        # толщина стен
FY = -50.0                      # верх пола
WINDOW = {"x": 0.0, "w": 170.0, "sill": 80.0, "h": 140.0}
DOOR = {"x": 100.0, "w": 80.0, "sill": 0.0, "h": 200.0}
BOUNDS = ((-230.0, 3.0, -180.0), (230.0, 193.0, 180.0))
LAMP_Y = 120.0   # высота лампы над столом (GFX): шнур и колба потолочной лампы рисуются на этом уровне

HX, HZ = SIZE[0] / 2.0, SIZE[2] / 2.0


def lin(c):
    """sRGB 0..1 -> линейный (COLOR_0 в glTF линейный; Godot читает цвета материалов как sRGB)"""
    def f(v):
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return tuple(f(v) for v in c)


# ---------------------------------------------------------------- геометрия (локальная, вокруг центра узла)

def _rot_matrix(rot):
    """Углы Эйлера в градусах как Godot rotation_degrees (порядок YXZ)"""
    rx, ry, rz = (math.radians(a) for a in rot)
    cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
    mx = ((1, 0, 0), (0, cx, -sx), (0, sx, cx))
    my = ((cy, 0, sy), (0, 1, 0), (-sy, 0, cy))
    mz = ((cz, -sz, 0), (sz, cz, 0), (0, 0, 1))

    def mul(a, b):
        return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))
    return mul(mul(my, mx), mz)


def _apply(m, v):
    return tuple(sum(m[i][k] * v[k] for k in range(3)) for i in range(3))


def _fix_winding(pos, nor, idx):
    out = []
    for i in range(0, len(idx), 3):
        a, b, c = idx[i:i + 3]
        pa, pb, pc = pos[a], pos[b], pos[c]
        e1 = tuple(pb[k] - pa[k] for k in range(3))
        e2 = tuple(pc[k] - pa[k] for k in range(3))
        n = (e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0])
        avg = tuple(sum(nor[j][k] for j in (a, b, c)) for k in range(3))
        if sum(n[k] * avg[k] for k in range(3)) < 0:
            b, c = c, b
        out += [a, b, c]
    return out


def _norm(v):
    ln = math.sqrt(sum(c * c for c in v)) or 1.0
    return tuple(c / ln for c in v)


def geom_box(size):
    pos, nor, uv, idx = fx._box_geometry(size)
    return pos, nor, uv, idx


def geom_cyl(r_bot, r_top, h, seg=16):
    pos, nor, uv, idx = [], [], [], []
    slope = (r_bot - r_top) / h
    for i in range(seg + 1):
        a = 2.0 * math.pi * i / seg
        ca, sa = math.cos(a), math.sin(a)
        n = _norm((ca, slope, sa))
        pos.append((r_bot * ca, -h / 2.0, r_bot * sa))
        nor.append(n)
        uv.append((i / seg, 1.0))
        pos.append((r_top * ca, h / 2.0, r_top * sa))
        nor.append(n)
        uv.append((i / seg, 0.0))
    for i in range(seg):
        b0, t0, b1, t1 = 2 * i, 2 * i + 1, 2 * i + 2, 2 * i + 3
        idx += [b0, b1, t1, b0, t1, t0]
    for top, r, y, ny in ((False, r_bot, -h / 2.0, -1.0), (True, r_top, h / 2.0, 1.0)):
        if r <= 0:
            continue
        c = len(pos)
        pos.append((0.0, y, 0.0))
        nor.append((0.0, ny, 0.0))
        uv.append((0.5, 0.5))
        for i in range(seg + 1):
            a = 2.0 * math.pi * i / seg
            pos.append((r * math.cos(a), y, r * math.sin(a)))
            nor.append((0.0, ny, 0.0))
            uv.append((0.5 + 0.5 * math.cos(a), 0.5 + 0.5 * math.sin(a)))
        for i in range(seg):
            idx += [c, c + 1 + i, c + 2 + i]
    return pos, nor, uv, _fix_winding(pos, nor, idx)


def geom_ball(r, squash=(1.0, 1.0, 1.0), seg=16, rings=8):
    rad = tuple(r * s for s in squash)
    pos, nor, uv, idx = [], [], [], []
    for j in range(rings + 1):
        th = math.pi * j / rings
        for i in range(seg + 1):
            ph = 2.0 * math.pi * i / seg
            p = (math.sin(th) * math.cos(ph), math.cos(th), math.sin(th) * math.sin(ph))
            pos.append(tuple(p[k] * rad[k] for k in range(3)))
            nor.append(_norm(tuple(p[k] / rad[k] for k in range(3))))
            uv.append((i / seg, j / rings))
    for j in range(rings):
        for i in range(seg):
            a = j * (seg + 1) + i
            b = a + seg + 1
            idx += [a, b, a + 1, a + 1, b, b + 1]
    return pos, nor, uv, _fix_winding(pos, nor, idx)


def geom_torus(inner, outer, seg=16, tube_seg=8):
    big = (inner + outer) / 2.0
    small = (outer - inner) / 2.0
    pos, nor, uv, idx = [], [], [], []
    for i in range(seg + 1):
        a = 2.0 * math.pi * i / seg
        ca, sa = math.cos(a), math.sin(a)
        for j in range(tube_seg + 1):
            b = 2.0 * math.pi * j / tube_seg
            cb, sb = math.cos(b), math.sin(b)
            pos.append(((big + small * cb) * ca, small * sb, (big + small * cb) * sa))
            nor.append((cb * ca, sb, cb * sa))
            uv.append((i / seg, j / tube_seg))
    for i in range(seg):
        for j in range(tube_seg):
            a = i * (tube_seg + 1) + j
            b = a + tube_seg + 1
            idx += [a, b, a + 1, a + 1, b, b + 1]
    return pos, nor, uv, _fix_winding(pos, nor, idx)


def geom_quad(w, h, colors=None):
    """Квад лицом на +Z, uv сверху вниз. colors: цвета четырёх вершин (левый верх, правый верх, правый низ, левый низ), RGBA"""
    x, y = w / 2.0, h / 2.0
    pos = [(-x, y, 0.0), (x, y, 0.0), (x, -y, 0.0), (-x, -y, 0.0)]
    nor = [(0.0, 0.0, 1.0)] * 4
    uv = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
    return pos, nor, uv, [0, 3, 2, 0, 2, 1] if False else [0, 3, 2, 0, 2, 1]


def geom_strip(w, h, alphas, rgb):
    """Квад лицом на +Z из полос по высоте: alphas[i] у строки вершин i сверху вниз (ложный AO: градиент прозрачности)"""
    n = len(alphas)
    pos, nor, uv, col, idx = [], [], [], [], []
    for i, a in enumerate(alphas):
        y = h / 2.0 - h * i / (n - 1)
        for x, u in ((-w / 2.0, 0.0), (w / 2.0, 1.0)):
            pos.append((x, y, 0.0))
            nor.append((0.0, 0.0, 1.0))
            uv.append((u, i / (n - 1)))
            col.append(rgb + (a,))
    for i in range(n - 1):
        a = 2 * i
        idx += [a, a + 2, a + 3, a, a + 3, a + 1]
    return pos, nor, uv, col, idx


def bake(geom, rot=None, color=None):
    """Геометрия с поворотом в вершинах и вершинным цветом (rot: градусы Эйлера, цвет sRGB)"""
    pos, nor, uv, idx = geom[:4]
    if rot and any(rot):
        m = _rot_matrix(rot)
        pos = [_apply(m, p) for p in pos]
        nor = [_apply(m, n) for n in nor]
    out = {"pos": pos, "nor": nor, "uv": uv, "idx": idx}
    if color is not None:
        c = lin(color) + (1.0,)
        out["col"] = [c] * len(pos)
    return out


# ---------------------------------------------------------------- сцена

class Builder:
    def __init__(self):
        self.nodes = []
        self.count = {}
        self.mats = set()
        self.nodes.append(fx.node("Room", None, extras={"role": "room"}))
        for gname, grole in fx.GROUPS:
            self.nodes.append(fx.node(gname, "Room", extras={"role": grole}))

    def _name(self, group, nm):
        key = (group, nm)
        self.count[key] = self.count.get(key, 0) + 1
        return "%s_%02d" % (nm, self.count[key]) if self.count[key] > 1 else nm

    def add(self, group, nm, geom, pos, role, color, rot=None, extras=None):
        mat = ROLES[role][0]
        self.mats.add(mat)
        n = fx.node(self._name(group, nm), group, tuple(pos), mat=mat, extras=extras, geom=bake(geom, rot, color))
        self.nodes.append(n)
        return n

    def box(self, group, nm, size, pos, role, color, rot=None, extras=None):
        return self.add(group, nm, geom_box(size), pos, role, color, rot, extras)

    def cyl(self, group, nm, r, h, pos, role, color, top_r=-1.0, rot=None):
        return self.add(group, nm, geom_cyl(r, r if top_r < 0 else top_r, h), pos, role, color, rot)

    def ball(self, group, nm, r, pos, role, color, squash=(1.0, 1.0, 1.0)):
        return self.add(group, nm, geom_ball(r, squash), pos, role, color, None)

    def proxy(self, nm, role, lo, hi, parent="Room", extras=None):
        pos = tuple((lo[i] + hi[i]) / 2.0 for i in range(3))
        size = tuple(hi[i] - lo[i] for i in range(3))
        ex = {"role": role}
        ex.update(extras or {})
        self.nodes.append(fx.node(nm, parent, pos, box=size, extras=ex))


def f(x, y, z):
    """Точка в координатах комнаты: y отсчитывается от пола"""
    return (x, FY + y, z)


def build_scene():
    b = Builder()
    wall = PALETTE["dusty"]

    # --- пол, потолок, стены
    b.box("Floor", "floor_slab", (SIZE[0] + 2 * T, T, SIZE[2] + 2 * T), (0.0, FY - T / 2.0, 0.0), "wood", FLOOR_COLOR)
    b.box("Ceiling", "ceiling_slab", (SIZE[0] + 2 * T, T, SIZE[2] + 2 * T), (0.0, FY + SIZE[1] + T / 2.0, 0.0), "paint", CEILING_COLOR)

    def slab(nm, x0, x1, y0, y1, cz):
        if x1 - x0 > 0.01 and y1 - y0 > 0.01:
            b.box("Shell", nm, (x1 - x0, y1 - y0, T), ((x0 + x1) / 2.0, (y0 + y1) / 2.0, cz), "paint", wall)

    def wall_z(sgn, op, tag):
        cz = sgn * (HZ + T / 2.0)
        x0, x1 = -HX - T, HX + T
        y0, y1 = FY, FY + SIZE[1]
        l, r = op["x"] - op["w"] / 2.0, op["x"] + op["w"] / 2.0
        s0 = y0 + op["sill"]
        s1 = s0 + op["h"]
        if op["sill"] > 0:
            slab(tag + "_below", x0, x1, y0, s0, cz)
        if s1 < y1:
            slab(tag + "_above", x0, x1, s1, y1, cz)
        slab(tag + "_left", x0, l, s0, s1, cz)
        slab(tag + "_right", r, x1, s0, s1, cz)

    wall_z(-1.0, WINDOW, "wall_n")
    wall_z(1.0, DOOR, "wall_s")
    for sgn, tag in ((-1.0, "wall_w"), (1.0, "wall_e")):
        b.box("Shell", tag, (T, SIZE[1], SIZE[2]), (sgn * (HX + T / 2.0), FY + SIZE[1] / 2.0, 0.0), "paint", wall)

    # --- рама окна (рисунок окна и тени), штора, карниз, подоконник: оболочка
    cz = -(HZ + T / 2.0)
    s0 = FY + WINDOW["sill"]
    wh, ww, ox = WINDOW["h"], WINDOW["w"], WINDOW["x"]
    fb = 4.0
    b.box("Shell", "frame_top", (ww, fb, 3.0), (ox, s0 + wh - fb / 2.0, cz), "paint", FRAME_COLOR)
    b.box("Shell", "frame_bottom", (ww, fb, 3.0), (ox, s0 + fb / 2.0, cz), "paint", FRAME_COLOR)
    b.box("Shell", "frame_left", (fb, wh, 3.0), (ox - ww / 2.0 + fb / 2.0, s0 + wh / 2.0, cz), "paint", FRAME_COLOR)
    b.box("Shell", "frame_right", (fb, wh, 3.0), (ox + ww / 2.0 - fb / 2.0, s0 + wh / 2.0, cz), "paint", FRAME_COLOR)
    b.box("Shell", "mullion_v", (3.0, wh, 2.0), (ox, s0 + wh / 2.0, cz), "paint", FRAME_COLOR)
    b.box("Shell", "mullion_h", (ww, 3.0, 2.0), (ox, s0 + wh * 0.55, cz), "paint", FRAME_COLOR)
    top = WINDOW["sill"] + WINDOW["h"]
    curtain = PALETTE["yellow"]
    b.cyl("Shell", "curtain_rod", 1.0, ww + 56.0, f(ox, top + 6.0, -183.0), "metal", PALETTE["grey"], rot=(0, 0, 90))
    hang = top + 4.0 - (WINDOW["sill"] - 14.0)
    cy = (top + 4.0 + (WINDOW["sill"] - 14.0)) / 2.0
    b.box("Shell", "curtain_left", (26.0, hang, 3.0), f(ox - ww / 2.0 - 14.0, cy, -183.0), "fabric", curtain)
    b.box("Shell", "curtain_right", (26.0, hang, 3.0), f(ox + ww / 2.0 + 14.0, cy, -183.0), "fabric", curtain)
    b.box("Shell", "window_sill", (ww + 16.0, 4.0, 16.0), f(ox, WINDOW["sill"] - 2.0, -182.0), "paint", PALETTE["white"])

    # --- T1: мебель
    T1 = "DecorT1"
    bedding = PALETTE["red"]
    big = {"role": "furniture"}
    b.box(T1, "bed_frame", (90, 22, 200), f(-195, 11, -90), "wood", PALETTE["wood_light"], extras=big)
    b.box(T1, "bed_mattress", (86, 14, 194), f(-195, 29, -90), "fabric", PALETTE["white"])
    b.box(T1, "bed_blanket", (87, 3, 130), f(-195, 37.5, -56), "fabric", bedding)
    b.ball(T1, "bed_pillow", 12.0, f(-195, 40, -172), "fabric", PALETTE["white"], (1.6, 0.5, 1.0))
    b.box(T1, "bed_headboard", (90, 50, 4), f(-195, 25, -188), "wood", PALETTE["wood_dark"])
    b.box(T1, "bed_footboard", (90, 28, 4), f(-195, 14, 8), "wood", PALETTE["wood_dark"])

    b.box(T1, "desk_top", (60, 4, 120), f(210, 73, 40), "wood", PALETTE["wood_light"], extras=big)
    b.box(T1, "desk_side_n", (56, 71, 3), f(210, 35.5, -18.5), "wood", PALETTE["wood_light"])
    b.box(T1, "desk_side_s", (56, 71, 3), f(210, 35.5, 98.5), "wood", PALETTE["wood_light"])
    b.box(T1, "desk_back", (3, 40, 114), f(237.5, 50, 40), "wood", PALETTE["wood_dark"])
    b.box(T1, "desk_cabinet", (52, 45, 46), f(212, 24.5, 70), "paint", PALETTE["white"])
    for i, y in enumerate((15, 36)):
        b.box(T1, "desk_drawer", (1, 18, 42), f(185.5, y, 70), "paint", PALETTE["cream"])
        b.ball(T1, "desk_knob", 1.4, f(184.5, y, 70), "plastic", PALETTE["yellow"])

    b.box(T1, "chair_seat", (36, 4, 36), f(160, 43, 40), "plastic", PALETTE["orange"], extras=big)
    b.box(T1, "chair_back", (4, 34, 36), f(143, 62, 40), "plastic", PALETTE["orange"])
    for sx in (-15.0, 15.0):
        for sz in (-15.0, 15.0):
            b.cyl(T1, "chair_leg", 1.5, 41.0, f(160 + sx, 20.5, 40 + sz), "metal", PALETTE["grey"])

    b.box(T1, "wardrobe_body", (100, 200, 48), f(-190, 100, 166), "wood", PALETTE["wood_light"], extras=big)
    b.box(T1, "wardrobe_door", (48.5, 194, 2), f(-215, 100, 141), "paint", PALETTE["white"])
    b.box(T1, "wardrobe_door", (48.5, 194, 2), f(-165, 100, 141), "paint", PALETTE["white"])
    b.box(T1, "wardrobe_handle", (1.5, 14, 1.5), f(-194, 100, 139), "metal", PALETTE["grey"])
    b.box(T1, "wardrobe_handle", (1.5, 14, 1.5), f(-186, 100, 139), "metal", PALETTE["grey"])
    b.box(T1, "wardrobe_top", (104, 4, 52), f(-190, 202, 165), "wood", PALETTE["wood_dark"])

    b.box(T1, "shelf_side", (3, 180, 30), f(161.5, 90, -175), "wood", PALETTE["wood_light"], extras=big)
    b.box(T1, "shelf_side", (3, 180, 30), f(238.5, 90, -175), "wood", PALETTE["wood_light"])
    for y in (1.5, 45.0, 90.0, 135.0, 178.5):
        b.box(T1, "shelf_board", (80, 3, 28), f(200, y, -176), "wood", PALETTE["wood_light"])
    b.box(T1, "shelf_back", (80, 180, 2), f(200, 90, -189), "wood", PALETTE["wood_dark"])

    # ковёр с дорогами
    b.box(T1, "rug", (160, 0.6, 110), f(0, 0.3, 125), "fabric", PALETTE["green"])
    b.box(T1, "rug_road_x", (160, 0.2, 22), f(0, 0.7, 125), "fabric", PALETTE["grey"])
    b.box(T1, "rug_road_z", (22, 0.2, 110), f(-30, 0.7, 125), "fabric", PALETTE["grey"])
    for i in range(-3, 4):
        x = i * 20.0
        if abs(x + 30.0) > 14.0:
            b.box(T1, "rug_dash", (8, 0.1, 1.6), f(x, 0.9, 125), "fabric", PALETTE["yellow"])

    # дверь в проёме южной стены
    dx, dw, dh = DOOR["x"], DOOR["w"], DOOR["h"]
    b.box(T1, "door_leaf", (dw - 4.0, dh - 4.0, 3), f(dx, (dh - 4.0) / 2.0, 192), "paint", PALETTE["white"])
    b.box(T1, "door_jamb", (4, dh, 6), f(dx - dw / 2.0, dh / 2.0, 193), "wood", PALETTE["wood_light"])
    b.box(T1, "door_jamb", (4, dh, 6), f(dx + dw / 2.0, dh / 2.0, 193), "wood", PALETTE["wood_light"])
    b.box(T1, "door_head", (dw + 4.0, 4, 6), f(dx, dh + 2.0, 193), "wood", PALETTE["wood_light"])
    b.box(T1, "door_handle", (6, 1.5, 1.5), f(dx - dw / 2.0 + 8.0, 100, 190), "metal", PALETTE["grey"])

    # потолочная лампа над столом: шнур, плафон, колба (светится вместе с лампой GFX)
    top_y = FY + SIZE[1]
    cord = top_y - (LAMP_Y + 12.0)
    b.cyl(T1, "lamp_cord", 0.4, max(cord, 4.0), (0.0, LAMP_Y + 12.0 + cord / 2.0, 0.0), "paint", PALETTE["dark"])
    b.cyl(T1, "lamp_shade", 3.0, 12.0, (0.0, LAMP_Y + 6.0, 0.0), "paint", PALETTE["yellow"], top_r=11.0)
    bulb = b.ball(T1, "bulb_lamp", 3.5, (0.0, LAMP_Y - 1.0, 0.0), "plastic", (1.0, 0.92, 0.75))
    bulb["mat"] = "emit_bulb"
    bulb["extras"] = {"role": "bulb", "bulb_of": "gfx_lamp"}

    # --- T2: характер
    T2 = "DecorT2"
    for i, c in enumerate(["red", "blue", "yellow", "green", "orange", "purple"]):
        x = 166.0 + i * 11.0
        b.box(T2, "model_box", (6, 20, 14), f(x, 56.5, -176), "paper", PALETTE[c])
        b.box(T2, "model_box_label", (6.4, 3, 14.4), f(x, 50.5, -176), "paper", PALETTE["white"])
    rng = random.Random(7)
    keys = ["red", "blue", "green", "orange", "purple", "yellow", "sky"]
    x = 164.0
    while x < 236.0 - 3.0:
        w = rng.uniform(2.0, 3.6)
        if x + w > 236.0:
            break
        h = rng.uniform(15.0, 23.0)
        b.box(T2, "book", (w, h, 14.0), f(x + w / 2.0, 91.5 + h / 2.0, -176.0), "paper", PALETTE[keys[rng.randrange(len(keys))]])
        x += w + 0.1
    b.box(T2, "toolbox", (14, 8, 10), f(225, 79, 10), "metal", PALETTE["red"])
    b.box(T2, "toolbox_handle", (8, 1.5, 1.5), f(225, 84.5, 10), "metal", PALETTE["grey"])
    b.cyl(T2, "desk_lamp_base", 5.0, 2.0, f(230, 76, 85), "metal", PALETTE["dark"])
    b.box(T2, "desk_lamp_arm", (1.5, 30, 1.5), f(228, 91, 85), "metal", PALETTE["grey"], rot=(0, 0, 14))
    b.cyl(T2, "desk_lamp_head", 6.0, 8.0, f(222, 105, 85), "paint", PALETTE["yellow"], top_r=2.0)
    b.cyl(T2, "globe_stand", 4.0, 1.0, f(200, 75.5, -8), "metal", PALETTE["dark"])
    b.ball(T2, "globe", 7.0, f(200, 83, -8), "plastic", PALETTE["blue"])
    b.add(T2, "globe_ring", geom_torus(7.6, 8.2), f(200, 83, -8), "metal", PALETTE["grey"], rot=(0, 0, 23))
    for px, d, zc in ((-239.5, 1.0, -90.0), (239.5, -1.0, 40.0)):
        c0, c1, c2 = PALETTE["blue"], PALETTE["red"], PALETTE["yellow"]
        b.box(T2, "poster", (1, 40, 60), f(px, 150, zc), "paper", c0)
        b.box(T2, "poster_stripe", (1.2, 14, 36), f(px + d * 0.2, 144, zc), "paper", c1)
        b.box(T2, "poster_dot", (1.2, 10, 10), f(px + d * 0.2, 147, zc - 14), "paper", c2)
        b.box(T2, "poster_dot", (1.2, 6, 6), f(px + d * 0.2, 162, zc + 16), "paper", c2)
    b.box(T2, "backpack", (24, 34, 12), f(150, 17, 92), "fabric", PALETTE["slate"])
    b.box(T2, "backpack_pocket", (20, 14, 5), f(150, 10, 86), "fabric", PALETTE["yellow"])

    # --- T3: мелочи
    T3 = "DecorT3"
    b.cyl(T3, "mug", 3.0, 8.0, f(232, 79, -10), "plastic", PALETTE["orange"])
    for i, c in enumerate(("red", "blue", "green")):
        b.cyl(T3, "brush", 0.4, 12.0, f(232 + (i - 1) * 1.4, 87, -10), "wood", PALETTE[c], rot=(0, 0, (i - 1) * 12.0))
    for i, c in enumerate(("green", "red", "blue")):
        b.box(T3, "notebook", (16, 1.2, 22), f(215, 75.6 + i * 1.3, 55), "paper", PALETTE[c])
    b.ball(T3, "football", 11.0, f(40, 11, 140), "plastic", PALETTE["white"])
    for v in ((0, 10, 4), (8, 4, 6), (-7, 6, 5)):
        b.ball(T3, "football_patch", 3.2, f(40 + v[0] * 0.95, 11 + v[1] * 0.95, 140 + v[2] * 0.95), "plastic", PALETTE["dark"], (1.0, 1.0, 0.5))
    for i, c in enumerate(("red", "yellow", "blue", "green")):
        b.box(T3, "toy_block", (5, 5, 5), f(-70 + i * 6.0, 3.1, 150 - (i % 2) * 5.0), "plastic", PALETTE[c], rot=(0, i * 20.0, 0))
    b.box(T3, "sneaker", (10, 6, 22), f(-130, 3, 20), "fabric", PALETTE["dark"])
    b.box(T3, "sneaker", (10, 6, 22), f(-116, 3, 24), "fabric", PALETTE["red"], rot=(0, 12, 0))
    b.ball(T3, "teddy_body", 7.0, f(-195, 45, -20), "fabric", PALETTE["brown"])
    b.ball(T3, "teddy_head", 5.0, f(-195, 55, -20), "fabric", PALETTE["brown"])
    b.ball(T3, "teddy_ear", 2.0, f(-199, 59.5, -20), "fabric", PALETTE["brown"])
    b.ball(T3, "teddy_ear", 2.0, f(-191, 59.5, -20), "fabric", PALETTE["brown"])

    # --- ложный AO: квады с градиентом прозрачности в вершинах, без освещения
    AO = "FakeAO"
    ao_rgb = (0.05, 0.07, 0.16)
    ao_h, ao_w, gap = 60.0, 32.0, 0.3
    y0, hh = FY, SIZE[1]
    floor_a = (0.55, 0.55 * 0.35, 0.0)   # у пола: тёмный низ, к верху прозрачнее
    corner_a = (0.55, 0.55 * 0.35, 0.0)

    def ao_quad(nm, w, h, pos, rot_y, alphas_top_to_bottom=None, flip=False, along_x=False):
        # floor_strip: градиент по высоте (тёмный низ); corner: по ширине (тёмный левый край)
        if along_x:   # угол: узкая полоса, градиент слева направо -> повернём геометрию квада 90° вокруг z нельзя (нормаль), поэтому полосы по ширине
            n = len(corner_a)
            pos_l, nor_l, uv_l, col_l, idx_l = [], [], [], [], []
            for i, a in enumerate(corner_a):
                x = -w / 2.0 + w * i / (n - 1)
                if flip:
                    x = -x
                for y, v in ((h / 2.0, 0.0), (-h / 2.0, 1.0)):
                    pos_l.append((x, y, 0.0))
                    nor_l.append((0.0, 0.0, 1.0))
                    uv_l.append((i / (n - 1), v))
                    col_l.append(lin(ao_rgb) + (a,))
            for i in range(n - 1):
                a_ = 2 * i
                idx_l += [a_, a_ + 1, a_ + 3, a_, a_ + 3, a_ + 2]
            geom = {"pos": pos_l, "nor": nor_l, "uv": uv_l, "idx": _fix_winding(pos_l, nor_l, idx_l), "col": col_l}
        else:
            pos_l, nor_l, uv_l, col_l, idx_l = geom_strip(w, h, tuple(reversed(floor_a)), lin(ao_rgb))
            geom = {"pos": pos_l, "nor": nor_l, "uv": uv_l, "idx": _fix_winding(pos_l, nor_l, idx_l), "col": col_l}
        geom = _rotate_geom(geom, (0.0, math.degrees(rot_y), 0.0))
        b.mats.add("glass_fake_ao")
        b.nodes.append(fx.node(b._name(AO, nm), AO, tuple(pos), mat="glass_fake_ao", geom=geom))

    ao_quad("floor_n", SIZE[0], ao_h, (0.0, y0 + ao_h / 2.0, -HZ + gap), 0.0)
    ao_quad("floor_w", SIZE[2], ao_h, (-HX + gap, y0 + ao_h / 2.0, 0.0), math.pi / 2.0)
    ao_quad("floor_e", SIZE[2], ao_h, (HX - gap, y0 + ao_h / 2.0, 0.0), -math.pi / 2.0)
    ao_quad("corner_n_w", ao_w, hh, (-HX + ao_w / 2.0, y0 + hh / 2.0, -HZ + gap), 0.0, along_x=True)
    ao_quad("corner_w_n", ao_w, hh, (-HX + gap, y0 + hh / 2.0, -HZ + ao_w / 2.0), math.pi / 2.0, along_x=True, flip=True)
    ao_quad("corner_w_s", ao_w, hh, (-HX + gap, y0 + hh / 2.0, HZ - ao_w / 2.0), math.pi / 2.0, along_x=True)
    ao_quad("corner_n_e", ao_w, hh, (HX - ao_w / 2.0, y0 + hh / 2.0, -HZ + gap), 0.0, along_x=True, flip=True)
    ao_quad("corner_e_n", ao_w, hh, (HX - gap, y0 + hh / 2.0, -HZ + ao_w / 2.0), -math.pi / 2.0, along_x=True)
    ao_quad("corner_e_s", ao_w, hh, (HX - gap, y0 + hh / 2.0, HZ - ao_w / 2.0), -math.pi / 2.0, along_x=True, flip=True)

    # --- небо за окном (GFX красит его градиентом: материал в игре заменяется)
    sky_pos = (WINDOW["x"], FY + SIZE[1] * 0.35, -HZ - 150.0)
    sky = geom_quad(700.0, 350.0)
    b.mats.add("emit_sky")
    b.nodes.append(fx.node("sky_card", "DecorT1", sky_pos, mat="emit_sky", extras={"role": "sky_card"}, geom=bake(sky, None, (0.6, 0.8, 0.95))))

    # --- прокси: коллизия, проёмы, объём, границы камеры
    lo_f = (-HX - T, FY - T, -HZ - T)
    hi_f = (HX + T, FY, HZ + T)
    b.proxy("collider_floor", "collider", lo_f, hi_f, extras={"shape": "box"})
    for nm, sgn_x, sgn_z in (("collider_wall_n", None, -1), ("collider_wall_s", None, 1)):
        b.proxy(nm, "collider", (-HX - T, FY, sgn_z * HZ - (T if sgn_z < 0 else 0.0)), (HX + T, FY + SIZE[1], sgn_z * HZ + (0.0 if sgn_z < 0 else T)), extras={"shape": "box"})
    b.proxy("collider_wall_w", "collider", (-HX - T, FY, -HZ), (-HX, FY + SIZE[1], HZ), extras={"shape": "box"})
    b.proxy("collider_wall_e", "collider", (HX, FY, -HZ), (HX + T, FY + SIZE[1], HZ), extras={"shape": "box"})
    props = (("bed", (90, 45, 200), (-195, -90)), ("desk", (60, 75, 120), (210, 40)), ("chair", (40, 45, 40), (160, 40)),
             ("wardrobe", (100, 200, 50), (-190, 165)), ("shelf", (80, 180, 30), (200, -175)))
    for nm, sz, (px, pz) in props:
        b.proxy("collider_" + nm, "collider", (px - sz[0] / 2.0, FY, pz - sz[2] / 2.0), (px + sz[0] / 2.0, FY + sz[1], pz + sz[2] / 2.0), extras={"shape": "box"})
    s0 = FY + WINDOW["sill"]
    b.proxy("window_n", "window", (WINDOW["x"] - WINDOW["w"] / 2.0, s0, -HZ - T), (WINDOW["x"] + WINDOW["w"] / 2.0, s0 + WINDOW["h"], -HZ))
    d0 = FY + DOOR["sill"]
    b.proxy("door_s", "door", (DOOR["x"] - DOOR["w"] / 2.0, d0, HZ), (DOOR["x"] + DOOR["w"] / 2.0, d0 + DOOR["h"], HZ + T))
    b.proxy("camera_bounds", "camera_bounds", BOUNDS[0], BOUNDS[1])
    b.proxy("room_volume", "room_volume", (-HX, FY, -HZ), (HX, FY + SIZE[1], HZ))
    b.nodes.append(fx.node("table_origin", "Room", (0.0, 0.0, 0.0), extras={"role": "table_origin"}))
    b.nodes.append(fx.node("window_sun", "Room", (0.0, FY + SIZE[1] * 0.6, -HZ - 5.0), rot=fx.arrow_quat((0.35, -0.55, 0.75)), extras={"role": "window_sun"}))

    mat_defs = {}
    for role, (nm, rough, metal) in ROLES.items():
        mat_defs[nm] = {"color": [1.0, 1.0, 1.0, 1.0], "roughness": rough, "metallic": metal}
    mat_defs["wood_kid"]["double_sided"] = False
    mat_defs["emit_bulb"] = {"color": [1.0, 0.92, 0.75, 1.0], "roughness": 0.4, "emissive": [1.0, 0.82, 0.55]}
    mat_defs["emit_sky"] = {"color": [1.0, 1.0, 1.0, 1.0], "roughness": 1.0, "unlit": True}
    mat_defs["glass_fake_ao"] = {"color": [1.0, 1.0, 1.0, 1.0], "roughness": 1.0, "unlit": True, "blend": True, "double_sided": True}
    return {"nodes": b.nodes, "glb_scale": 1.0, "mat_defs": mat_defs}


def _rotate_geom(geom, rot):
    m = _rot_matrix(rot)
    out = dict(geom)
    out["pos"] = [_apply(m, p) for p in geom["pos"]]
    out["nor"] = [_apply(m, n) for n in geom["nor"]]
    return out


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    sc = build_scene()
    os.makedirs(os.path.dirname(os.path.abspath(argv[0])), exist_ok=True)
    with open(argv[0], "wb") as fh:
        fh.write(fx.to_glb(sc))
    print("Записано: %s (узлов %d)" % (argv[0], len(sc["nodes"])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
