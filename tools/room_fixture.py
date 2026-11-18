#!/usr/bin/env python3
"""room_fixture: эталонная комната и «испорченные» варианты для проверки пайплайна комнат (ATTN_25 §25.7, RM7).

Без Blender и без Godot, только Python 3.8+. Описание сцены в метрах, оси Godot (север это -Z, вверх +Y); в .glb длины пишутся в сантиметрах
(x100, 1 единица = 1 см игры, GLB_SCALE): так выглядит файл, который даёт экспорт Blender по CHEATSHEET_ROOM.md (Unit Scale 0.01). Нужен для двух вещей:
  1. data/models/room_test_01/room_test_01.glb: эталон «по одному объекту каждой роли», его читает glb_preflight.py --kind room
     и (RM8) Godot. Пересобрать:  python tools/room_fixture.py data/models/room_test_01/room_test_01.glb
     Когда автор соберёт room_test_01 в Blender, экспорт из Blender заменяет этот файл.
  2. tools/test_room_pipeline.py: те же правила на сценах с поломками (две роли room, .001, лампа без ctl_id и так далее).

    python tools/room_fixture.py out.glb [--broken <имя поломки>]     # --broken list: список
"""
import copy
import json
import math
import struct
import sys

GLB_SCALE = 100.0   # метров -> единиц файла (1 единица = 1 см игры)
GROUPS = (("Floor", "floor"), ("Shell", "shell"), ("Ceiling", "ceiling"), ("DecorT1", "decor_t1"), ("DecorT2", "decor_t2"), ("DecorT3", "decor_t3"), ("FakeAO", "fake_ao"))


def node(name, parent, pos=(0.0, 0.0, 0.0), box=None, mat=None, extras=None, rot=None, scale=None, **kw):
    """Узел сцены. box: размер коробки вокруг начала узла (метры); extras: Custom Properties; rot: кватернион (x, y, z, w)"""
    d = {"name": name, "parent": parent, "pos": tuple(pos), "box": box, "mat": mat, "extras": dict(extras or {}), "rot": rot, "scale": scale}
    d.update(kw)
    return d


def box_node(name, parent, lo, hi, mat=None, extras=None, **kw):
    pos = tuple((lo[i] + hi[i]) / 2.0 for i in range(3))
    size = tuple(hi[i] - lo[i] for i in range(3))
    return node(name, parent, pos, size, mat, extras, **kw)


def arrow_quat(direction):
    """Кватернион, поворачивающий локальную +Y glTF (стрелка пустышки: +Z Blender) в направление direction"""
    dx, dy, dz = direction
    ln = math.sqrt(dx * dx + dy * dy + dz * dz)
    dx, dy, dz = dx / ln, dy / ln, dz / ln
    # кратчайший поворот от (0, 1, 0) к (dx, dy, dz)
    cx, cy, cz = dz, 0.0, -dx   # (0, 1, 0) x d
    w = 1.0 + dy
    if w < 1e-6:
        return (1.0, 0.0, 0.0, 0.0)
    q = (cx, cy, cz, w)
    n = math.sqrt(sum(c * c for c in q))
    return tuple(c / n for c in q)


def reference_scene():
    """Эталон room_test_01: комната 4.8 x 2.5 x 3.8 м (карточка 480 x 250 x 380 см), стол на нуле, пол на -0.5 м"""
    n = []
    n.append(node("Room", None, extras={"role": "room"}))
    for gname, grole in GROUPS:
        n.append(node(gname, "Room", extras={"role": grole}))
    # пол
    n.append(box_node("floor_slab", "Floor", (-2.4, -0.6, -1.9), (2.4, -0.5, 1.9), "wood_floor"))
    # стены: север с окном x -0.85..0.85, y 0.30..1.70; юг с дверью x 0.6..1.4, y -0.5..1.5; запад, восток
    w = "paint_wall"
    n.append(box_node("wall_n_left", "Shell", (-2.5, -0.5, -2.0), (-0.85, 2.0, -1.9), w))
    n.append(box_node("wall_n_right", "Shell", (0.85, -0.5, -2.0), (2.5, 2.0, -1.9), w))
    n.append(box_node("wall_n_sill", "Shell", (-0.85, -0.5, -2.0), (0.85, 0.30, -1.9), w))
    n.append(box_node("wall_n_head", "Shell", (-0.85, 1.70, -2.0), (0.85, 2.0, -1.9), w))
    n.append(box_node("wall_s_left", "Shell", (-2.5, -0.5, 1.9), (0.6, 2.0, 2.0), w))
    n.append(box_node("wall_s_right", "Shell", (1.4, -0.5, 1.9), (2.5, 2.0, 2.0), w))
    n.append(box_node("wall_s_head", "Shell", (0.6, 1.5, 1.9), (1.4, 2.0, 2.0), w))
    n.append(box_node("wall_w", "Shell", (-2.5, -0.5, -1.9), (-2.4, 2.0, 1.9), w))
    n.append(box_node("wall_e", "Shell", (2.4, -0.5, -1.9), (2.5, 2.0, 1.9), w))
    n.append(box_node("curtain", "Shell", (-0.95, 0.2, -1.88), (0.95, 1.8, -1.84), "fabric_curtain",
                      {"role": "mech_part", "ctl": "mech", "ctl_id": "curtain", "ctl_title": "Штора", "ctl_scope": "observe", "ctl_default": 0}))
    # потолок
    n.append(box_node("ceiling_slab", "Ceiling", (-2.4, 2.0, -1.9), (2.4, 2.1, 1.9), "paint_ceiling"))
    # ярус 1: крупная мебель
    n.append(box_node("bed", "DecorT1", (-2.3, -0.5, 0.6), (-0.3, 0.0, 1.8), "fabric_bed", {"role": "furniture"}))
    n.append(box_node("wardrobe", "DecorT1", (1.6, -0.5, -1.8), (2.3, 1.5, -0.9), "wood_wardrobe", {"role": "furniture"}))
    # ярус 2: характер
    n.append(box_node("shelf", "DecorT2", (-2.3, 1.2, -1.8), (-1.5, 1.25, -1.4), "wood_shelf", {"role": "prop"}))
    n.append(box_node("lamp_a_body", "DecorT2", (-1.15, 1.94, -0.15), (-0.85, 2.0, 0.15), "metal_lamp"))
    n.append(box_node("bulb_lamp_a", "DecorT2", (-1.05, 1.88, -0.05), (-0.95, 1.94, 0.05), "emit_bulb", {"role": "bulb", "bulb_of": "lamp_a"}))
    # ярус 3: мелочи
    n.append(box_node("book", "DecorT3", (-2.0, 1.25, -1.675), (-1.8, 1.29, -1.525), "paper_book", {"role": "prop"}))
    # ложный AO
    n.append(box_node("ao_bed", "FakeAO", (-2.3, -0.499, 0.6), (-0.3, -0.498, 1.8), "paint_fake_ao"))
    # прокси-коробки
    n.append(box_node("collider_floor", "Room", (-2.4, -0.6, -1.9), (2.4, -0.5, 1.9), None, {"role": "collider", "shape": "box"}))
    n.append(box_node("collider_bed", "Room", (-2.3, -0.5, 0.6), (-0.3, 0.0, 1.8), None, {"role": "collider", "shape": "box"}))
    n.append(box_node("collider_wardrobe", "Room", (1.6, -0.5, -1.8), (2.3, 1.5, -0.9), None, {"role": "collider", "shape": "box"}))
    n.append(box_node("window_n", "Room", (-0.85, 0.30, -2.0), (0.85, 1.70, -1.9), None, {"role": "window"}))
    n.append(box_node("door_s", "Room", (0.6, -0.5, 1.9), (1.4, 1.5, 2.0), None, {"role": "door"}))
    n.append(box_node("camera_bounds", "Room", (-2.3, 0.03, -1.8), (2.3, 1.93, 1.8), None, {"role": "camera_bounds"}))
    n.append(box_node("room_volume", "Room", (-2.4, -0.5, -1.9), (2.4, 2.0, 1.9), None, {"role": "room_volume"}))
    # метки и свет
    n.append(node("table_origin", "Room", (0.0, 0.0, 0.0), extras={"role": "table_origin"}))
    n.append(node("window_sun", "Room", (0.0, 1.0, -1.95), rot=arrow_quat((0.35, -0.55, 0.75)), extras={"role": "window_sun"}))
    n.append(node("lamp_ceiling_a", "Room", (-1.0, 1.95, 0.0), rot=(1.0, 0.0, 0.0, 0.0), extras={
        "role": "light", "light_kind": "spot", "light_energy": 150, "light_range": 400, "light_angle": 70, "light_color": "#fff2dd", "light_shadow": 1,
        "ctl": "toggle", "ctl_id": "lamp_a", "ctl_title": "Потолочная лампа", "ctl_scope": "observe", "ctl_default": 1}))
    n.append(node("lamp_ceiling_b", "Room", (1.0, 1.95, 0.0), rot=(1.0, 0.0, 0.0, 0.0), extras={
        "role": "light", "light_kind": "omni", "light_energy": 100, "light_range": 300, "light_color": "#ffffff", "light_shadow": 0,
        "ctl": "toggle", "ctl_id": "lamp_b", "ctl_title": "Подсветка", "ctl_scope": "studio", "ctl_default": 1}))
    anims = [{"name": "mech_curtain", "channels": [{"target": "curtain", "path": "translation", "times": [0.0, 1.0], "values": [(0.0, 1.0, -1.86), (1.6, 1.0, -1.86)]}]}]
    return {"nodes": n, "animations": anims, "images": [], "cameras": False, "punctual": False}


# ---------------------------------------------------------------- поломки: каждая меняет эталон так, чтобы сработало одно правило

def _find(sc, name):
    return next(x for x in sc["nodes"] if x["name"] == name)


def _add_lights(sc, count, shadow):
    for i in range(count):
        sc["nodes"].append(node("lamp_extra_%d" % i, "Room", (0.1 * i, 1.9, 0.5), rot=(1.0, 0.0, 0.0, 0.0), extras={
            "role": "light", "light_kind": "omni", "light_energy": 50, "light_range": 200, "light_shadow": 1 if i < shadow else 0}))


def _two_rooms(sc):
    sc["nodes"].append(node("Room_b", None, extras={"role": "room"}))


def _dup_suffix(sc):
    _find(sc, "bed")["name"] = "bed.001"


def _default_name(sc):
    _find(sc, "book")["name"] = "Cube"


def _space_name(sc):
    _find(sc, "shelf")["name"] = "big shelf"


def _no_ctl_id(sc):
    del _find(sc, "lamp_ceiling_a")["extras"]["ctl_id"]


def _scale(sc):
    _find(sc, "wardrobe")["scale"] = (0.9, 0.9, 0.9)


def _proxy_rot(sc):
    _find(sc, "collider_bed")["rot"] = (0.0, 0.3826834, 0.0, 0.9238795)


def _no_bulb_of(sc):
    del _find(sc, "bulb_lamp_a")["extras"]["bulb_of"]


def _bulb_gfx_lamp(sc):
    "колба с лампой над столом (bulb_of = gfx_lamp): допустимо, лампы комнаты не нужны"
    _find(sc, "bulb_lamp_a")["extras"]["bulb_of"] = "gfx_lamp"


def _bulb_of_bad(sc):
    _find(sc, "bulb_lamp_a")["extras"]["bulb_of"] = "lamp_zzz"


def _no_anim(sc):
    sc["animations"] = []


def _anim_orphan(sc):
    _find(sc, "curtain")["extras"]["ctl_id"] = "blind"


def _anim_two(sc):
    sc["animations"][0]["channels"].append({"target": "curtain", "path": "rotation", "times": [0.0, 1.0], "values": [(0.0, 0.0, 0.0, 1.0), (0.0, 0.3826834, 0.0, 0.9238795)]})


def _anim_still(sc):
    sc["animations"][0]["channels"][0]["values"] = [(0.0, 1.0, -1.86), (0.0, 1.0, -1.86)]


def _anim_norole(sc):
    del _find(sc, "curtain")["extras"]["role"]


def _lights_17(sc):
    _add_lights(sc, 15, 0)


def _lights_13(sc):
    _add_lights(sc, 11, 0)


def _shadows_5(sc):
    _add_lights(sc, 4, 4)


def _volume_small(sc):
    n = _find(sc, "room_volume")
    n["pos"] = (0.0, 0.75, 0.0)
    n["box"] = (2.4, 2.5, 1.2)


def _floor_high(sc):
    _find(sc, "floor_slab")["pos"] = (0.0, -0.45, 0.0)


def _ctl_dup(sc):
    _find(sc, "lamp_ceiling_b")["extras"]["ctl_id"] = "lamp_a"


def _slider_mesh(sc):
    _find(sc, "wardrobe")["extras"].update({"ctl": "slider", "ctl_id": "wardrobe_dim"})


def _ctl_bad_kind(sc):
    _find(sc, "lamp_ceiling_b")["extras"]["ctl"] = "dimmer"


def _no_floor_collider(sc):
    sc["nodes"] = [x for x in sc["nodes"] if x["name"] != "collider_floor"]


def _floor_mesh_group(sc):
    "role floor на самом меше пола (как у реального экспорта): это группа из одного меша, замечаний нет"
    fl = _find(sc, "floor_slab")
    fl["extras"] = {"role": "floor"}
    fl["parent"] = "Room"
    sc["nodes"] = [x for x in sc["nodes"] if x["name"] != "Floor"]


def _no_floor(sc):
    sc["nodes"] = [x for x in sc["nodes"] if x["name"] not in ("Floor", "floor_slab")]


def _material_dup(sc):
    _find(sc, "wall_n_left")["mat"] = "paint_wall.001"


def _materials_41(sc):
    for i in range(40):
        sc["nodes"].append(box_node("trinket_%d" % i, "DecorT3", (0.0, 0.0, 0.0), (0.01, 0.01, 0.01), "paper_t%d" % i))


def _texture_big(sc):
    sc["images"] = [{"name": "atlas_big", "w": 8192, "h": 8192}]


def _textures_5(sc):
    sc["images"] = [{"name": "atlas_%d" % i, "w": 2048, "h": 2048} for i in range(5)]


def _tris_many(sc):
    _find(sc, "wardrobe")["tris_extra"] = 125000


def _in_meters(sc):
    sc["glb_scale"] = 1.0


def _camera_node(sc):
    sc["cameras"] = True


def _punctual(sc):
    sc["punctual"] = True


def _light_params(sc):
    _find(sc, "lamp_ceiling_b")["extras"].update({"light_energy": -5, "light_color": "white"})


def _window_wrong_wall(sc):
    n = _find(sc, "window_n")
    n["pos"] = (0.0, 1.0, 1.95)


def _stray_mesh(sc):
    sc["nodes"].append(box_node("loose_box", "Room", (0.0, 0.0, 0.0), (0.2, 0.2, 0.2), "paint_wall"))


def _role_dup(sc):
    _find(sc, "ceiling_slab")["extras"]["role"] = "floor"


def _group_ctl(sc):
    """Две лампы одной группой: общий ctl_group, свои ctl_id. Поломок нет: правило должно пройти"""
    for nm in ("lamp_ceiling_a", "lamp_ceiling_b"):
        _find(sc, nm)["extras"]["ctl_group"] = "ceiling_lamps"
        _find(sc, nm)["extras"]["ctl_scope"] = "observe"


BROKEN = {
    # имя: (функция, уровень, ключевая фраза в отчёте)
    "two_rooms": (_two_rooms, "ERROR", "role = room: 2"),
    "dup_suffix": (_dup_suffix, "ERROR", "хвост дубля"),
    "default_name": (_default_name, "ERROR", "имя по умолчанию"),
    "space_name": (_space_name, "ERROR", "пробел в имени"),
    "no_ctl_id": (_no_ctl_id, "ERROR", "ctl без ctl_id"),
    "scale": (_scale, "ERROR", "масштаб"),
    "proxy_rot": (_proxy_rot, "ERROR", "Коробка без поворота"),
    "no_bulb_of": (_no_bulb_of, "ERROR", "без bulb_of"),
    "bulb_gfx_lamp": (_bulb_gfx_lamp, "OK", ""),
    "bulb_of_bad": (_bulb_of_bad, "ERROR", "лампы с таким ctl_id"),
    "no_anim": (_no_anim, "ERROR", "действия mech_curtain нет"),
    "anim_orphan": (_anim_orphan, "ERROR", "нет объекта с ctl = mech и ctl_id = 'curtain'"),
    "anim_two": (_anim_two, "ERROR", "и сдвиг, и поворот"),
    "anim_still": (_anim_still, "ERROR", "движения между ключами нет"),
    "anim_norole": (_anim_norole, "ERROR", "без роли"),
    "lights_17": (_lights_17, "ERROR", "Ламп (якорей light) 17"),
    "lights_13": (_lights_13, "WARN", "Ламп (якорей light) 13"),
    "shadows_5": (_shadows_5, "ERROR", "Ламп с тенью"),
    "volume_small": (_volume_small, "ERROR", "не помещается"),
    "floor_high": (_floor_high, "WARN", "Верх пола"),
    "ctl_dup": (_ctl_dup, "ERROR", "не уникален"),
    "slider_mesh": (_slider_mesh, "ERROR", "slider работает только"),
    "ctl_bad_kind": (_ctl_bad_kind, "ERROR", "допустимо toggle, slider, mech"),
    "no_floor_collider": (_no_floor_collider, "WARN", "коллайдера пола"),
    "floor_mesh_group": (_floor_mesh_group, "OK", ""),
    "no_floor": (_no_floor, "ERROR", "Нет объекта с role = floor"),
    "material_dup": (_material_dup, "ERROR", "Материал 'paint_wall.001'"),
    "materials_41": (_materials_41, "ERROR", "Материалов 51"),
    "texture_big": (_texture_big, "ERROR", "Текстура 'atlas_big'"),
    "textures_5": (_textures_5, "ERROR", "Текстур по 2048"),
    "tris_many": (_tris_many, "ERROR", "Треугольников"),
    "in_meters": (_in_meters, "ERROR", "не помещается"),
    "camera_node": (_camera_node, "ERROR", "камеры"),
    "punctual": (_punctual, "ERROR", "Punctual Lights"),
    "light_params": (_light_params, "ERROR", "light_energy"),
    "window_wrong_wall": (_window_wrong_wall, "WARN", "в южной стене"),
    "stray_mesh": (_stray_mesh, "WARN", "вне групп"),
    "role_dup": (_role_dup, "ERROR", "Роль 'floor' у 2 объектов"),
    "group_ctl": (_group_ctl, "OK", ""),
}


def broken_scene(name):
    sc = copy.deepcopy(reference_scene())
    BROKEN[name][0](sc)
    return sc


# ---------------------------------------------------------------- запись .glb

def _box_geometry(size):
    hx, hy, hz = (s / 2.0 for s in size)
    faces = [  # нормаль, 4 вершины против часовой стрелки снаружи
        ((1, 0, 0), [(hx, -hy, hz), (hx, -hy, -hz), (hx, hy, -hz), (hx, hy, hz)]),
        ((-1, 0, 0), [(-hx, -hy, -hz), (-hx, -hy, hz), (-hx, hy, hz), (-hx, hy, -hz)]),
        ((0, 1, 0), [(-hx, hy, hz), (hx, hy, hz), (hx, hy, -hz), (-hx, hy, -hz)]),
        ((0, -1, 0), [(-hx, -hy, -hz), (hx, -hy, -hz), (hx, -hy, hz), (-hx, -hy, hz)]),
        ((0, 0, 1), [(-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz)]),
        ((0, 0, -1), [(hx, -hy, -hz), (-hx, -hy, -hz), (-hx, hy, -hz), (hx, hy, -hz)]),
    ]
    pos, nor, uv, idx = [], [], [], []
    for nrm, quad in faces:
        k = len(pos)
        for i, v in enumerate(quad):
            pos.append(v)
            nor.append(nrm)
            uv.append(((0, 0), (1, 0), (1, 1), (0, 1))[i])
        idx += [k, k + 1, k + 2, k, k + 2, k + 3]
    return pos, nor, uv, idx


def _png_header(w, h):
    return b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", w, h) + b"\x08\x02\x00\x00\x00" + b"\x00\x00\x00\x00"


def to_glb(sc):
    """Описание сцены -> байты .glb (длины x GLB_SCALE; sc["glb_scale"] = 1.0 имитирует комнату, нарисованную в метрах)"""
    GLB_SCALE = sc.get("glb_scale", globals()["GLB_SCALE"])
    binb = bytearray()
    views, accs = [], []

    def add_view(data, target=None):
        while len(binb) % 4:
            binb.append(0)
        v = {"buffer": 0, "byteOffset": len(binb), "byteLength": len(data)}
        if target:
            v["target"] = target
        binb.extend(data)
        views.append(v)
        return len(views) - 1

    def add_acc(view, ctype, count, atype, mn=None, mx=None):
        a = {"bufferView": view, "componentType": ctype, "count": count, "type": atype}
        if mn is not None:
            a["min"], a["max"] = list(mn), list(mx)
        accs.append(a)
        return len(accs) - 1

    mat_index, materials = {}, []
    mat_defs = sc.get("mat_defs", {})
    unlit = False
    for nd in sc["nodes"]:
        m = nd.get("mat")
        if m and m not in mat_index:
            mat_index[m] = len(materials)
            d = mat_defs.get(m, {})
            mt = {"name": m, "pbrMetallicRoughness": {"baseColorFactor": list(d.get("color", [0.8, 0.8, 0.8, 1.0])),
                  "metallicFactor": d.get("metallic", 0.0), "roughnessFactor": d.get("roughness", 0.9)}}
            if m.startswith("glass_") or d.get("blend"):
                mt["alphaMode"] = "BLEND"
            if d.get("emissive"):
                mt["emissiveFactor"] = list(d["emissive"])
            if d.get("unlit"):
                mt["extensions"] = {"KHR_materials_unlit": {}}
                unlit = True
            if d.get("double_sided"):
                mt["doubleSided"] = True
            materials.append(mt)
    meshes = []
    mesh_of = {}
    gnodes = []
    for i, nd in enumerate(sc["nodes"]):
        g = {"name": nd["name"]}
        if nd["pos"] != (0.0, 0.0, 0.0):
            g["translation"] = [float(c) * GLB_SCALE for c in nd["pos"]]
        if nd.get("rot"):
            g["rotation"] = [float(c) for c in nd["rot"]]
        if nd.get("scale"):
            g["scale"] = [float(c) for c in nd["scale"]]
        if nd["extras"]:
            g["extras"] = dict(nd["extras"])
        if nd.get("box") or nd.get("geom"):
            col = None
            if nd.get("geom"):
                pos, nor, uv, idx = (nd["geom"][k] for k in ("pos", "nor", "uv", "idx"))
                col = nd["geom"].get("col")
                pos = [tuple(c * GLB_SCALE for c in p) for p in pos]
            else:
                pos, nor, uv, idx = _box_geometry(tuple(c * GLB_SCALE for c in nd["box"]))
            pb = b"".join(struct.pack("<3f", *p) for p in pos)
            nb = b"".join(struct.pack("<3f", *p) for p in nor)
            ub = b"".join(struct.pack("<2f", *p) for p in uv)
            ib = b"".join(struct.pack("<H", k) for k in idx)
            cb = b"".join(struct.pack("<4f", *c) for c in col) if col else None
            mn = [min(p[k] for p in pos) for k in range(3)]
            mx = [max(p[k] for p in pos) for k in range(3)]
            attrs = {"POSITION": add_acc(add_view(pb, 34962), 5126, len(pos), "VEC3", mn, mx),
                     "NORMAL": add_acc(add_view(nb, 34962), 5126, len(pos), "VEC3"),
                     "TEXCOORD_0": add_acc(add_view(ub, 34962), 5126, len(pos), "VEC2")}
            if cb:
                attrs["COLOR_0"] = add_acc(add_view(cb, 34962), 5126, len(pos), "VEC4")
            prims = [{"attributes": attrs, "indices": add_acc(add_view(ib, 34963), 5123, len(idx), "SCALAR"), "mode": 4}]
            if nd.get("mat"):
                prims[0]["material"] = mat_index[nd["mat"]]
            if nd.get("tris_extra"):
                extra = b"".join(struct.pack("<H", 0) for _ in range(nd["tris_extra"] * 3))
                p2 = {"attributes": attrs, "indices": add_acc(add_view(extra, 34963), 5123, nd["tris_extra"] * 3, "SCALAR"), "mode": 4}
                if nd.get("mat"):
                    p2["material"] = mat_index[nd["mat"]]
                prims.append(p2)
            meshes.append({"name": nd["name"], "primitives": prims})
            g["mesh"] = len(meshes) - 1
        gnodes.append(g)
    by_name = {nd["name"]: i for i, nd in enumerate(sc["nodes"])}
    roots = []
    for i, nd in enumerate(sc["nodes"]):
        if nd["parent"] is None:
            roots.append(i)
        else:
            gnodes[by_name[nd["parent"]]].setdefault("children", []).append(i)
    if sc.get("cameras"):
        gnodes.append({"name": "view_camera", "camera": 0, "translation": [0.0, 1.0, 0.0]})
        gnodes[0].setdefault("children", []).append(len(gnodes) - 1)
    anims = []
    for a in sc.get("animations", []):
        samplers, channels = [], []
        for ch in a["channels"]:
            tview = add_view(b"".join(struct.pack("<f", t) for t in ch["times"]))
            n_comp = 4 if ch["path"] == "rotation" else 3
            k = GLB_SCALE if ch["path"] == "translation" else 1.0
            vview = add_view(b"".join(struct.pack("<%df" % n_comp, *(c * k for c in v)) for v in ch["values"]))
            tacc = add_acc(tview, 5126, len(ch["times"]), "SCALAR", [min(ch["times"])], [max(ch["times"])])
            vacc = add_acc(vview, 5126, len(ch["values"]), "VEC4" if n_comp == 4 else "VEC3")
            samplers.append({"input": tacc, "output": vacc, "interpolation": "LINEAR"})
            channels.append({"sampler": len(samplers) - 1, "target": {"node": by_name[ch["target"]], "path": ch["path"]}})
        anims.append({"name": a["name"], "samplers": samplers, "channels": channels})
    images = []
    for im in sc.get("images", []):
        images.append({"name": im["name"], "mimeType": "image/png", "bufferView": add_view(_png_header(im["w"], im["h"]))})
    g = {"asset": {"version": "2.0", "generator": "ec-project room_fixture"}, "scene": 0, "scenes": [{"nodes": roots}], "nodes": gnodes,
         "buffers": [{"byteLength": len(binb)}], "bufferViews": views, "accessors": accs}
    if meshes:
        g["meshes"] = meshes
    if materials:
        g["materials"] = materials
    if anims:
        g["animations"] = anims
    if images:
        g["images"] = images
        g["textures"] = [{"source": i} for i in range(len(images))]
    if sc.get("cameras"):
        g["cameras"] = [{"type": "perspective", "perspective": {"yfov": 0.8, "znear": 0.1}}]
    if unlit:
        g["extensionsUsed"] = ["KHR_materials_unlit"]
    if sc.get("punctual"):
        g["extensionsUsed"] = ["KHR_lights_punctual"]
        g["extensions"] = {"KHR_lights_punctual": {"lights": [{"type": "point", "intensity": 100}]}}
    js = json.dumps(g, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    js += b" " * ((4 - len(js) % 4) % 4)
    binb = bytes(binb) + b"\x00" * ((4 - len(binb) % 4) % 4)
    total = 12 + 8 + len(js) + 8 + len(binb)
    return b"glTF" + struct.pack("<II", 2, total) + struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(binb), 0x004E4942) + binb


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if "--broken" in argv:
        name = argv[argv.index("--broken") + 1]
        if name == "list":
            print("\n".join(sorted(BROKEN)))
            return 0
        sc = broken_scene(name)
    else:
        sc = reference_scene()
    with open(argv[0], "wb") as f:
        f.write(to_glb(sc))
    print("Записано: %s" % argv[0])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
