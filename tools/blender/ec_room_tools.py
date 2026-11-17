"""ec_room_tools: помощник Blender для экспорта комнат в ec-project (ATTN_25 §25.7, шпаргалка: tools/blender/CHEATSHEET_ROOM.md).

Как пользоваться
  1. В Blender открыть вкладку Scripting, Open, выбрать этот файл, Run Script. В 3D-окне справа (клавиша N) появится вкладка «EC Room».
     Постоянно: Edit, Preferences, Add-ons, Install from Disk, выбрать этот файл. Работает рядом с ec_model_tools.py (вагоны): имена не пересекаются.
  2. Без интерфейса (проверка перед коммитом):
        blender -b art/blender/room_test_01.blend -P tools/blender/ec_room_tools.py -- check
        blender -b art/blender/room_test_01.blend -P tools/blender/ec_room_tools.py -- export --id room_test_01
     Код возврата 1, если проверка нашла ошибки.

Что делает
  Проверка: берёт корень комнаты (Empty с Custom Property role = room) и всё, что в него вложено, и сверяет с правилами ATTN_25 §25.7.5:
  роли и их число, имена, масштаб и поворот, прокси-коробки, свет якорями, управление (ctl_*), механизмы mech_<id>, материалы, текстуры, треугольники.
  Помощники: роли и свойства, прокси-коробки, якоря света, применить трансформы, эталон «стол и пол», ключи механизма.
  Экспорт: glb с настройками комнаты, затем tools/glb_preflight.py --kind room по готовому файлу.
Из Blender ничего не пишется в репозиторий, кроме самого .glb.

Устройство. Правила написаны один раз над «снимком» сцены (обычные словари и числа, без bpy): `snapshot(scene)` снимает сцену Blender,
`check_room(snap)` проверяет. Тот же `check_room` использует tools/glb_preflight.py, собирая снимок из готового .glb: комната проверяется
одним набором правил и до экспорта, и после. Без Blender файл импортируется (bpy пуст), работает только проверка. Скрипт ставится одним файлом.
Снимок в осях Blender, метры: +X восток, +Y север, +Z вверх; ноль по высоте на столешнице.
Единицы файла и сцены Blender: 1 единица = 1 см игры (комната 480 x 380 x 250 единиц, Unit Scale 0.01); в снимок всё переводится в метры (UNIT).
"""
bl_info = {
    "name": "EC room tools",
    "author": "ec-project",
    "version": (1, 0, 0),
    "blender": (4, 2, 0),
    "location": "3D Viewport > Sidebar (N) > EC Room",
    "description": "Проверка и экспорт комнат для ec-project",
    "category": "Import-Export",
}

import math
import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import bpy
except ImportError:  # проверку правил можно запускать и без Blender (glb_preflight.py --kind room)
    bpy = None

# ---------------------------------------------------------------- правила (ATTN_25 §25.7; держать в синхроне с документом)

ROLE_RE = re.compile(r"^[a-z][a-z0-9_]*$")
DUP_SUFFIX = re.compile(r"[.]\d{3,}$")
DEFAULT_NAMES = re.compile(r"^(Cube|Plane|Sphere|Cylinder|Cone|Torus|Circle|Empty|Suzanne|Light|Camera|Icosphere|Grid)(\.\d+)?$", re.I)
DEBUG_NAMES = {"sphere", "frontmarker", "ax", "ay", "az", "marker"}
COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")

GROUP_ROLES = ("floor", "shell", "ceiling", "decor_t1", "decor_t2", "decor_t3", "fake_ao")
PROXY_ROLES = ("collider", "window", "door", "camera_bounds", "room_volume")
# роль -> (минимум, максимум; None без предела): §25.7.2, колонка «Сколько»
ROLE_COUNT = {
    "room": (1, 1), "floor": (1, 1), "shell": (1, 1), "ceiling": (0, 1), "decor_t1": (0, 1), "decor_t2": (0, 1), "decor_t3": (0, 1), "fake_ao": (0, 1),
    "collider": (0, None), "window": (0, None), "door": (0, None), "camera_bounds": (1, 1), "room_volume": (1, 1),
    "table_origin": (0, 1), "window_sun": (0, 1), "sky_card": (0, None), "bulb": (0, None), "light": (0, None), "mech_part": (0, None),
    "furniture": (0, None), "prop": (0, None),
}
CTL_KINDS = ("toggle", "slider", "mech")
CTL_SCOPES = ("observe", "studio")
LIGHT_KINDS = ("spot", "omni")
MAT_PREFIXES = ("paint_", "wood_", "fabric_", "metal_", "plastic_", "paper_", "glass_", "emit_")

TRI_WARN, TRI_ERROR = 80000, 120000
GROUP_TRI_WARN = {"decor_t1": 40000, "decor_t2": 20000, "decor_t3": 15000}
SHELL_TRI_WARN = 8000      # пол, стены и потолок вместе
OBJECT_TRI_WARN = 8000
MAT_WARN, MAT_ERROR = 24, 40
TEX_WARN_COUNT, TEX_ERROR_COUNT = 2, 4   # текстур по 2048 и крупнее
TEX_MAX, TEX_HARD_MAX = 2048, 4096
LIGHT_WARN, LIGHT_ERROR = 12, 16
SHADOW_WARN, SHADOW_ERROR = 2, 4
FLOOR_TOP, FLOOR_TOL = -0.50, 0.05       # верх пола при столе 0.5 м, метры
VOLUME_WARN = ((3.0, 8.0), (2.2, 3.5), (3.0, 8.0))   # размер room_volume: ширина X, высота, глубина (оси Godot)
TABLE_X, TABLE_Z, PASSAGE = 2.0, 1.0, 0.3            # подмакетник 200 x 100 см и проход вокруг него
VOLUME_MIN_H = 1.0
MECH_PREFIX = "mech_"
UNIT = 0.01   # метров в одной единице Blender и .glb: 1 единица = 1 см игры (ATTN_25 §25.7.1)


def to_godot(v, k=1.0):
    """Оси Blender (x, y, z) -> оси Godot (x, z, -y), множитель k (100: метры в сантиметры игры)"""
    return (v[0] * k, v[2] * k, -v[1] * k)


def _num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def role_of_props(props):
    r = props.get("role")
    return r if isinstance(r, str) else None


def check_room(snap):
    """Правила §25.7.5 и числа §25.7.3 над снимком сцены. Возвращает [(level, text, node_id|None)], level: ERROR, WARN, INFO.

    snap = {
      "nodes": [{"id", "name", "parent" (id|None), "kind" (MESH, EMPTY, CAMERA, LIGHT, OTHER), "props" (Custom Properties объекта),
                 "data_role" (role стоит на данных меша), "pos" (мировое положение, м), "scale", "rot_deg" (поворот в покое),
                 "aim" (куда смотрит стрелка пустышки: локальная +Z, мировой вектор), "bbox" ((lo, hi) мировой габарит меша, м),
                 "tris", "mats" (имена материалов)}],
      "materials": {имя: {"transparent": bool}}, "images": [{"name", "w", "h"}],
      "actions": [{"name", "targets" [id], "kinds" (что реально движется: move, rot), "scale_moved", "nonlinear", "frames" (a, b), "stub" (необязательно)}],
      "strays": [имена объектов вне корня, не попадающих в экспорт], "extras_present": bool}
    """
    items = []

    def add(level, text, nid=None):
        items.append((level, text, nid))

    nodes = snap.get("nodes", [])
    by_id = {n["id"]: n for n in nodes}
    kids = {}
    for n in nodes:
        kids.setdefault(n["parent"], []).append(n["id"])

    def role(n):
        return role_of_props(n["props"])

    def desc(nid):
        out = []
        for c in kids.get(nid, []):
            out.append(c)
            out.extend(desc(c))
        return out

    def members(nid):
        "узел и всё внутри него: группа может быть пустышкой с мешами или самим мешем (role на меше)"
        return [nid] + desc(nid)

    def ancestors(nid):
        out = []
        p = by_id[nid]["parent"]
        while p is not None and p in by_id:
            out.append(p)
            p = by_id[p]["parent"]
        return out

    def nm(nid):
        return by_id[nid]["name"]

    # ---- корень ----
    rooms = [n for n in nodes if role(n) == "room"]
    if len(rooms) != 1:
        add("ERROR", "Объектов с Custom Property role = room: %d, нужен ровно один (корень комнаты)." % len(rooms))
        if not snap.get("extras_present", True):
            add("INFO", "Ни у одного узла нет extras (ролей). Если роли в Blender назначены, в экспорте не включено Include, Custom Properties "
                        "(панель EC Room включает сама); роль должна стоять на объекте, не на данных меша.")
        return items
    root = rooms[0]
    rid = root["id"]
    if root["parent"] is not None:
        add("ERROR", "Корень комнаты (room) не должен иметь родителя.", rid)
    if root["kind"] != "EMPTY":
        add("ERROR", "Корень комнаты (room) должен быть пустышкой (Empty), сейчас %s." % root["kind"], rid)
    for n in nodes:
        if n["parent"] is None and n["id"] != rid:
            add("ERROR", "Корневых объектов больше одного: '%s' лежит рядом с корнем комнаты. Всё остальное должно быть детьми корня." % n["name"], n["id"])
    for s in snap.get("strays", []):
        add("WARN", "Объект '%s' лежит рядом с корнем комнаты и не войдёт в экспорт. Если он нужен, сделайте его потомком корня; если это эталон, оставьте в коллекции EC_ref." % s)
    if any(abs(c) > 1e-3 for c in root["pos"]):
        add("WARN", "Корень комнаты смещён от начала координат (%.1f, %.1f, %.1f см): ноль комнаты должен быть в центре комнаты на уровне столешницы." % tuple(c * 100.0 for c in root["pos"]), rid)

    inside = [by_id[c] for c in desc(rid)]
    export = [root] + inside

    # ---- имена, лишние узлы ----
    for n in export:
        name = n["name"]
        if DUP_SUFFIX.search(name):
            add("ERROR", "Объект '%s': хвост дубля (.001). Переименуйте." % name, n["id"])
        if " " in name:
            add("ERROR", "Объект '%s': пробел в имени, используйте _." % name, n["id"])
        if DEFAULT_NAMES.match(name):
            add("ERROR", "Объект '%s': имя по умолчанию (Cube, Plane, Empty...), дайте осмысленное." % name, n["id"])
        if name.lower() in DEBUG_NAMES:
            add("ERROR", "Объект '%s': отладочный узел, в рабочую комнату не экспортируется." % name, n["id"])
        if n["kind"] in ("CAMERA", "LIGHT"):
            add("ERROR", "Объект '%s' (%s) в комнате: камеры и Punctual Lights не экспортируются. Свет задаётся якорем role = light." % (name, n["kind"]), n["id"])

    # ---- роли ----
    roles = {}
    for n in export:
        raw = n["props"].get("role")
        r = role_of_props(n["props"])
        if raw is not None and r is None:
            add("ERROR", "Объект '%s': role должна быть строкой." % n["name"], n["id"])
        if n.get("data_role"):
            add("ERROR", "Объект '%s': role стоит на данных меша (Object Data), а нужна на объекте (вкладка Object, Custom Properties): иначе игра роль не увидит." % n["name"], n["id"])
        if r is None:
            continue
        if not ROLE_RE.match(r):
            add("ERROR", "Объект '%s': роль '%s': только a-z, 0-9, _, начинается с буквы." % (n["name"], r), n["id"])
            continue
        if r not in ROLE_COUNT:
            add("WARN", "Объект '%s': роль '%s' не из списка комнаты (§25.7.2), игра её не использует." % (n["name"], r), n["id"])
        roles.setdefault(r, []).append(n)
    for r, (lo_n, hi_n) in ROLE_COUNT.items():
        cnt = len(roles.get(r, []))
        if r == "room":
            continue
        if cnt < lo_n:
            add("ERROR", "Нет объекта с role = %s (нужен %s)." % (r, "один" if hi_n == 1 else "хотя бы один"))
        if hi_n is not None and cnt > hi_n:
            add("ERROR", "Роль '%s' у %d объектов (%s): допустим один." % (r, cnt, ", ".join(o["name"] for o in roles[r])))

    # ---- тип объекта по роли ----
    for r in GROUP_ROLES:
        for n in roles.get(r, []):
            if n["kind"] not in ("EMPTY", "MESH"):
                add("WARN", "Группа '%s' (role=%s) должна быть пустышкой (меши внутри) или одним мешем." % (n["name"], r), n["id"])
            if n["parent"] != rid:
                add("WARN", "Группа '%s' (role=%s) должна быть прямым ребёнком корня комнаты." % (n["name"], r), n["id"])
            if not [c for c in members(n["id"]) if by_id[c]["kind"] == "MESH"]:
                add("WARN", "Группа '%s' (role=%s) пуста: в ней нет мешей." % (n["name"], r), n["id"])
    for r in PROXY_ROLES:
        for n in roles.get(r, []):
            if n["kind"] != "MESH" or n.get("bbox") is None:
                add("ERROR", "Прокси '%s' (role=%s) должна быть коробкой (меш Cube)." % (n["name"], r), n["id"])
            elif n.get("mats"):
                add("WARN", "Прокси '%s' (role=%s) с материалом: отображение Wire, материал не нужен (в игре узел удаляется)." % (n["name"], r), n["id"])
    for r in ("light", "table_origin", "window_sun"):
        for n in roles.get(r, []):
            if n["kind"] != "EMPTY":
                add("WARN", "Объект '%s' (role=%s) должен быть пустышкой." % (n["name"], r), n["id"])
    for r in ("sky_card", "bulb"):
        for n in roles.get(r, []):
            if n["kind"] != "MESH":
                add("WARN", "Объект '%s' (role=%s) должен быть мешем." % (n["name"], r), n["id"])

    # ---- трансформы ----
    proxy_ids = {n["id"] for r in PROXY_ROLES for n in roles.get(r, [])}
    for n in export:
        sc = n["scale"]
        if any(abs(c - 1.0) > 1e-4 for c in sc):
            add("ERROR", "Объект '%s': масштаб (%.3f, %.3f, %.3f). Нажмите «Применить трансформы» или Ctrl+A, Scale." % (n["name"], *sc), n["id"])
        if n["rot_deg"] > 0.01:
            r = role(n)
            if n["id"] in proxy_ids:
                add("ERROR", "Прокси '%s': поворот %.2f°. Коробка без поворота (игра читает её габарит по осям)." % (n["name"], n["rot_deg"]), n["id"])
            elif n["kind"] == "MESH" or r == "mech_part":
                add("WARN", "Объект '%s': поворот в покое %.2f°. Для мешей нужен Apply Rotation, для оси механизма тоже." % (n["name"], n["rot_deg"]), n["id"])

    # ---- меши, группы, треугольники ----
    group_of = {}   # id меша -> роль группы
    for r in GROUP_ROLES:
        for g in roles.get(r, []):
            for c in members(g["id"]):
                group_of.setdefault(c, r)
    meshes = [n for n in export if n["kind"] == "MESH" and n["id"] not in proxy_ids]
    for n in meshes:
        if n["id"] not in group_of:
            add("WARN", "Меш '%s' лежит вне групп (floor, shell, ceiling, decor_*, fake_ao): положите его в группу." % n["name"], n["id"])
        if n.get("tris", 0) > OBJECT_TRI_WARN:
            add("WARN", "Меш '%s': %d треугольников (больше %d): разбейте или упростите." % (n["name"], n["tris"], OBJECT_TRI_WARN), n["id"])
    tris_by_group = {}
    for n in meshes:
        tris_by_group[group_of.get(n["id"], "-")] = tris_by_group.get(group_of.get(n["id"], "-"), 0) + n.get("tris", 0)
    total = sum(tris_by_group.values())
    if total > TRI_ERROR:
        add("ERROR", "Треугольников %d, предел %d." % (total, TRI_ERROR))
    elif total > TRI_WARN:
        add("WARN", "Треугольников %d, бюджет %d." % (total, TRI_WARN))
    for r, lim in GROUP_TRI_WARN.items():
        if tris_by_group.get(r, 0) > lim:
            add("WARN", "Группа %s: %d треугольников, бюджет %d." % (r, tris_by_group[r], lim))
    shell_tris = sum(tris_by_group.get(r, 0) for r in ("floor", "shell", "ceiling"))
    if shell_tris > SHELL_TRI_WARN:
        add("WARN", "Пол, стены и потолок вместе: %d треугольников, бюджет %d." % (shell_tris, SHELL_TRI_WARN))

    # ---- материалы, текстуры ----
    mats = {}
    for n in meshes:
        if not n.get("mats"):
            add("WARN", "Меш '%s': нет материалов." % n["name"], n["id"])
        for m in n.get("mats", []):
            mats[m] = snap.get("materials", {}).get(m, {})
    if len(mats) > MAT_ERROR:
        add("ERROR", "Материалов %d, предел %d." % (len(mats), MAT_ERROR))
    elif len(mats) > MAT_WARN:
        add("WARN", "Материалов %d, бюджет %d." % (len(mats), MAT_WARN))
    for name, info in mats.items():
        if DUP_SUFFIX.search(name):
            add("ERROR", "Материал '%s': хвост дубля (.001), переименуйте или слейте." % name)
        if " " in name:
            add("ERROR", "Материал '%s': пробел в имени, используйте _." % name)
        if not name.lower().startswith(MAT_PREFIXES):
            add("WARN", "Материал '%s': имя не по роли (%s)." % (name, ", ".join(p + "..." for p in MAT_PREFIXES)))
        if info.get("transparent") and not name.lower().startswith(("glass_", "emit_")):
            add("WARN", "Материал '%s' прозрачный, но имя не glass_*/emit_*." % name)
    big = 0
    for im in snap.get("images", []):
        side = max(im["w"], im["h"])
        if side > TEX_HARD_MAX:
            add("ERROR", "Текстура '%s' %dx%d: больше %d." % (im["name"], im["w"], im["h"], TEX_HARD_MAX))
        elif side > TEX_MAX:
            add("WARN", "Текстура '%s' %dx%d: комната до %d." % (im["name"], im["w"], im["h"], TEX_MAX))
        if side >= TEX_MAX:
            big += 1
    if big > TEX_ERROR_COUNT:
        add("ERROR", "Текстур по %d и крупнее: %d, предел %d." % (TEX_MAX, big, TEX_ERROR_COUNT))
    elif big > TEX_WARN_COUNT:
        add("WARN", "Текстур по %d и крупнее: %d, бюджет %d (атласы или trim sheet)." % (TEX_MAX, big, TEX_WARN_COUNT))

    # ---- пол, объём, границы камеры ----
    floor_top = FLOOR_TOP
    floors = roles.get("floor", [])
    if floors:
        zs = [by_id[c]["bbox"][1][2] for c in members(floors[0]["id"]) if by_id[c]["kind"] == "MESH" and by_id[c].get("bbox")]
        if zs:
            floor_top = max(zs)
            if abs(floor_top - FLOOR_TOP) > FLOOR_TOL:
                add("WARN", "Верх пола на %.1f см от нуля, ожидается %.0f ±%.0f (стол 50 см, ноль на столешнице). Если стол другой высоты, так и задумано." %
                    (floor_top * 100.0, FLOOR_TOP * 100.0, FLOOR_TOL * 100.0), floors[0]["id"])
    if floors:
        tops = [c["bbox"][1][2] for c in roles.get("collider", []) if c.get("bbox")]
        if not any(abs(t - floor_top) <= FLOOR_TOL for t in tops):
            add("WARN", "Нет коллайдера пола: ни у одной коробки collider верх не лежит на уровне пола (%.0f см). Без него упавшее со стола пройдёт сквозь пол." % (floor_top * 100.0),
                floors[0]["id"])
    vol = (roles.get("room_volume") or [None])[0]
    cam = (roles.get("camera_bounds") or [None])[0]
    if vol is not None and vol.get("bbox"):
        lo, hi = vol["bbox"]
        w, d, h = hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]
        for val, (a, b), label in zip((w, h, d), VOLUME_WARN, ("ширина X", "высота", "глубина Z")):
            if val < a - 1e-6 or val > b + 1e-6:
                add("WARN", "room_volume: %s %.0f см вне %.0f..%.0f." % (label, val * 100.0, a * 100.0, b * 100.0), vol["id"])
        if w < TABLE_X + 2 * PASSAGE - 1e-6 or d < TABLE_Z + 2 * PASSAGE - 1e-6 or h < VOLUME_MIN_H:
            add("ERROR", "room_volume %.0f x %.0f x %.0f см (ширина x высота x глубина): стол %.0f x %.0f с проходом %.0f см с каждой стороны не помещается." % (w * 100.0, h * 100.0, d * 100.0, TABLE_X * 100.0, TABLE_Z * 100.0, PASSAGE * 100.0), vol["id"])
        if abs(lo[2] - floor_top) > FLOOR_TOL:
            add("WARN", "room_volume начинается на %.1f см, а верх пола на %.1f: объём считается от пола." % (lo[2] * 100.0, floor_top * 100.0), vol["id"])
        if abs((hi[0] + lo[0]) / 2.0) > 0.1 or abs((hi[1] + lo[1]) / 2.0) > 0.1:
            add("WARN", "Центр room_volume не в центре стола (X %.1f, Y %.1f см): ноль комнаты должен быть в центре комнаты." % ((hi[0] + lo[0]) * 50.0, (hi[1] + lo[1]) * 50.0), vol["id"])
        if cam is not None and cam.get("bbox"):
            cl, ch = cam["bbox"]
            if any(cl[k] < lo[k] - 1e-3 or ch[k] > hi[k] + 1e-3 for k in range(3)):
                add("WARN", "camera_bounds выходит за room_volume: камера может уйти сквозь стену.", cam["id"])
            if cl[2] < -1e-3:
                add("WARN", "camera_bounds ниже столешницы (Z %.1f см)." % (cl[2] * 100.0), cam["id"])

    # ---- управление (ctl_*) ----
    controls = {}   # ключ (группа или id) -> [узлы]
    ids = {}
    for n in export:
        p = n["props"]
        if "ctl" not in p:
            for k in ("ctl_id", "ctl_title", "ctl_scope", "ctl_default", "ctl_group"):
                if k in p:
                    add("WARN", "Объект '%s': есть %s, но нет ctl: объект не управляется." % (n["name"], k), n["id"])
                    break
            continue
        kind = p.get("ctl")
        cid = p.get("ctl_id")
        if kind not in CTL_KINDS:
            add("ERROR", "Объект '%s': ctl = %r, допустимо toggle, slider, mech." % (n["name"], kind), n["id"])
            continue
        if cid is None or cid == "":
            add("ERROR", "Объект '%s': ctl без ctl_id." % n["name"], n["id"])
            continue
        if not isinstance(cid, str) or not ROLE_RE.match(cid):
            add("ERROR", "Объект '%s': ctl_id %r: только a-z, 0-9, _, начинается с буквы." % (n["name"], cid), n["id"])
            continue
        scope = p.get("ctl_scope", "studio")
        if scope not in CTL_SCOPES:
            add("ERROR", "Объект '%s': ctl_scope = %r, допустимо observe или studio." % (n["name"], scope), n["id"])
        dv = p.get("ctl_default", 1 if kind != "mech" else 0)
        if not _num(dv) or dv < 0 or dv > 1:
            add("ERROR", "Объект '%s': ctl_default = %r, нужно число 0..1." % (n["name"], dv), n["id"])
        if "ctl_title" in p and not isinstance(p["ctl_title"], str):
            add("ERROR", "Объект '%s': ctl_title должна быть строкой." % n["name"], n["id"])
        grp = p.get("ctl_group", "")
        if grp != "" and (not isinstance(grp, str) or not ROLE_RE.match(grp)):
            add("ERROR", "Объект '%s': ctl_group %r: только a-z, 0-9, _, начинается с буквы." % (n["name"], grp), n["id"])
            grp = ""
        if kind == "slider" and role(n) != "light":
            add("ERROR", "Объект '%s': slider работает только на якоре света (role = light)." % n["name"], n["id"])
        ids.setdefault(cid, []).append((n, grp))
        controls.setdefault(grp or cid, []).append(n)
    for cid, lst in ids.items():
        if len(lst) > 1:
            groups = {g for _, g in lst}
            if len(groups) != 1 or "" in groups:
                add("ERROR", "ctl_id '%s' не уникален: %s. Одинаковый id допустим только у объектов с общим ctl_group." % (cid, ", ".join(n["name"] for n, _ in lst)))
    grouped = {g for lst in ids.values() for _, g in lst if g}
    for cid, lst in ids.items():
        if cid in grouped and any(g == "" for _, g in lst):
            add("ERROR", "ctl_id '%s' совпадает с ctl_group другого управления: ключом управления служит группа." % cid)
    for key, lst in controls.items():
        if len({n["props"].get("ctl") for n in lst}) > 1:
            add("ERROR", "Управление '%s': объекты одной группы (%s) с разным ctl." % (key, ", ".join(n["name"] for n in lst)))
        if len({n["props"].get("ctl_scope", "studio") for n in lst}) > 1:
            add("ERROR", "Управление '%s': объекты одной группы (%s) с разным ctl_scope." % (key, ", ".join(n["name"] for n in lst)))

    # ---- свет ----
    lights = roles.get("light", [])
    shadows = 0
    for n in lights:
        p = n["props"]
        kind = p.get("light_kind")
        if kind not in LIGHT_KINDS:
            add("ERROR", "Якорь '%s': light_kind = %r, допустимо spot или omni." % (n["name"], kind), n["id"])
        for key in ("light_energy", "light_range"):
            if not _num(p.get(key)) or p.get(key) <= 0:
                add("ERROR", "Якорь '%s': %s = %r, нужно положительное число (дальность в см, энергия Godot)." % (n["name"], key, p.get(key)), n["id"])
        if kind == "spot" and not (_num(p.get("light_angle")) and 0 < p["light_angle"] < 90):
            add("WARN", "Якорь '%s': у spot light_angle = %r, нужно число 1..89 градусов." % (n["name"], p.get("light_angle")), n["id"])
        if "light_color" in p and not (isinstance(p["light_color"], str) and COLOR_RE.match(p["light_color"])):
            add("ERROR", "Якорь '%s': light_color = %r, нужен вид #rrggbb." % (n["name"], p["light_color"]), n["id"])
        sh = p.get("light_shadow", 0)
        if sh not in (0, 1):
            add("ERROR", "Якорь '%s': light_shadow = %r, нужно 0 или 1." % (n["name"], sh), n["id"])
        elif sh == 1:
            shadows += 1
        if "ctl" not in p:
            add("INFO", "Якорь '%s' без ctl: свет горит всегда, управлять им нельзя." % n["name"], n["id"])
    if len(lights) > LIGHT_ERROR:
        add("ERROR", "Ламп (якорей light) %d, предел %d." % (len(lights), LIGHT_ERROR))
    elif len(lights) > LIGHT_WARN:
        add("WARN", "Ламп (якорей light) %d, бюджет %d." % (len(lights), LIGHT_WARN))
    if shadows > SHADOW_ERROR:
        add("ERROR", "Ламп с тенью %d, предел %d." % (shadows, SHADOW_ERROR))
    elif shadows > SHADOW_WARN:
        add("WARN", "Ламп с тенью %d, бюджет %d." % (shadows, SHADOW_WARN))
    light_keys = set()
    for n in lights:
        if isinstance(n["props"].get("ctl_id"), str):
            light_keys.add(n["props"]["ctl_id"])
        if isinstance(n["props"].get("ctl_group"), str) and n["props"]["ctl_group"]:
            light_keys.add(n["props"]["ctl_group"])
    for n in roles.get("bulb", []):
        bo = n["props"].get("bulb_of")
        if not isinstance(bo, str) or bo == "":
            add("ERROR", "Колба '%s' (role = bulb) без bulb_of: с какой лампой она светится?" % n["name"], n["id"])
        elif bo not in light_keys:
            add("ERROR", "Колба '%s': bulb_of = '%s', лампы с таким ctl_id или ctl_group нет." % (n["name"], bo), n["id"])

    # ---- механизмы ----
    acts = snap.get("actions", [])
    act_ids = {}
    for a in acts:
        aname = a["name"]
        if not aname.startswith(MECH_PREFIX):
            add("WARN", "Действие '%s': имя не mech_<id>. Механизмы называются mech_curtain и т. п." % aname)
            continue
        mid = aname[len(MECH_PREFIX):]
        act_ids[mid] = a
        carriers = [n for n in export if n["props"].get("ctl_id") == mid and n["props"].get("ctl") == "mech"]
        if not carriers:
            add("ERROR", "Действие '%s': нет объекта с ctl = mech и ctl_id = '%s'." % (aname, mid))
        kinds = set(a.get("kinds", []))
        if not kinds:
            add("ERROR", "Действие '%s': движения между ключами нет." % aname)
        elif len(kinds) > 1:
            add("ERROR", "Действие '%s': и сдвиг, и поворот. Одно движение на механизм: разделите на две детали." % aname)
        if len(a.get("targets", [])) > 1:
            add("ERROR", "Действие '%s' двигает %d объектов (%s): один механизм это один объект." % (aname, len(a["targets"]), ", ".join(nm(t) for t in a["targets"] if t in by_id)))
        if a.get("scale_moved"):
            add("WARN", "Действие '%s': анимация масштаба не поддерживается." % aname)
        if a.get("nonlinear"):
            add("WARN", "Действие '%s': интерполяция не Linear (плавность даёт игра)." % aname)
        for t in a.get("targets", []):
            if t not in by_id:
                continue
            if role_of_props(by_id[t]["props"]) is None:
                add("ERROR", "Действие '%s' двигает '%s' без роли: игра найдёт часть только по роли." % (aname, nm(t)), t)
            if carriers and not any(t == c["id"] or c["id"] in ancestors(t) for c in carriers):
                add("WARN", "Действие '%s' двигает '%s', а объект с ctl_id = '%s' другой: управление не найдёт движущуюся часть." % (aname, nm(t), mid), t)
    for n in export:
        if n["props"].get("ctl") == "mech" and isinstance(n["props"].get("ctl_id"), str) and n["props"]["ctl_id"] not in act_ids:
            add("ERROR", "Объект '%s': ctl = mech, а действия mech_%s нет (ключи: «Ключ: покой» и «Ключ: рабочее»)." % (n["name"], n["props"]["ctl_id"]), n["id"])
    for n in roles.get("mech_part", []):
        if "ctl" not in n["props"]:
            add("INFO", "Подвижная часть '%s' (mech_part) без ctl: двигать её нечем, кроме кода." % n["name"], n["id"])

    # ---- числа для карточки и сводка (INFO) ----
    add("INFO", "Мешей %d, материалов %d, треугольников %d (%s)." % (
        len(meshes), len(mats), total, ", ".join("%s %d" % (k, v) for k, v in sorted(tris_by_group.items()))))
    parts = ["floor_y = %.1f" % (floor_top * 100.0)]
    if vol is not None and vol.get("bbox"):
        lo, hi = vol["bbox"]
        parts.append("size = Vector3(%.1f, %.1f, %.1f)" % (100.0 * (hi[0] - lo[0]), 100.0 * (hi[2] - lo[2]), 100.0 * (hi[1] - lo[1])))
    if cam is not None and cam.get("bbox"):
        cl, ch = cam["bbox"]
        gl = to_godot((cl[0], ch[1], cl[2]), 100.0)   # угол с минимальными x, y(Godot), z(Godot): x = cl.x, y = cl.z, z = -ch.y
        parts.append("bounds = AABB(Vector3(%.1f, %.1f, %.1f), Vector3(%.1f, %.1f, %.1f))" % (
            gl[0], gl[1], gl[2], 100.0 * (ch[0] - cl[0]), 100.0 * (ch[2] - cl[2]), 100.0 * (ch[1] - cl[1])))
    for r, wall_n, wall_s in (("window", "north", "south"), ("door", "south", "north")):
        lst = sorted(roles.get(r, []), key=lambda o: o["name"])
        if not lst:
            add("INFO", "Нет объектов %s: %s." % (r, "окон нет, в карточке daylight = false" if r == "window" else "двери нет"))
            continue
        n = lst[0]
        if not n.get("bbox"):
            continue
        lo, hi = n["bbox"]
        dx, dy = hi[0] - lo[0], hi[1] - lo[1]
        centre_y = (hi[1] + lo[1]) / 2.0
        vy = ((vol["bbox"][1][1] + vol["bbox"][0][1]) / 2.0) if (vol is not None and vol.get("bbox")) else 0.0
        if dy > dx:
            add("WARN", "%s '%s' в боковой стене (толщина по X): карточка хранит только проём в северной или южной стене." % (r, n["name"]), n["id"])
            continue
        is_north = centre_y >= vy
        if (r == "window") != is_north:
            add("WARN", "%s '%s' в %s стене: карточка ждёт %s в %s (RoomConfig)." % (r, n["name"], "северной" if is_north else "южной", r, "северной" if r == "window" else "южной"), n["id"])
        parts.append('%s = {"x": %.1f, "w": %.1f, "sill": %.1f, "h": %.1f}' % (r, 100.0 * (hi[0] + lo[0]) / 2.0, 100.0 * dx, 100.0 * (lo[2] - floor_top), 100.0 * (hi[2] - lo[2])))
        if len(lst) > 1:
            add("INFO", "Проёмов %s %d: в карточку идёт первый по имени ('%s'), остальные только для сцены." % (r, len(lst), n["name"]))
    add("INFO", "Для карточки RoomConfig (числа в см, оси Godot): " + "; ".join(parts) + ".")
    tos = (roles.get("table_origin") or [None])[0]
    if tos is not None:
        g = to_godot(tos["pos"], 100.0)
        add("INFO", "table_origin '%s': центр стола в (%.1f, %.1f, %.1f) см." % (tos["name"], g[0], g[1], g[2]), tos["id"])
    sun = (roles.get("window_sun") or [None])[0]
    if sun is not None and sun.get("aim"):
        g = to_godot(sun["aim"])
        add("INFO", "window_sun '%s': луч идёт по вектору Godot (%.2f, %.2f, %.2f) (стрелка пустышки: локальная +Z)." % (sun["name"], g[0], g[1], g[2]), sun["id"])
    for n in lights:
        p = n["props"]
        g = to_godot(n["pos"], 100.0)
        aim = to_godot(n["aim"]) if n.get("aim") else None
        add("INFO", "Свет '%s': %s, энергия %s, дальность %s см, угол %s, цвет %s, тень %s; позиция (%.1f, %.1f, %.1f) см%s." % (
            n["name"], p.get("light_kind"), p.get("light_energy"), p.get("light_range"), p.get("light_angle", "-"), p.get("light_color", "#ffffff"),
            p.get("light_shadow", 0), g[0], g[1], g[2], ", направление (%.2f, %.2f, %.2f)" % aim if aim else ""), n["id"])
    n_obs = 0
    for key, lst in sorted(controls.items()):
        first = lst[0]
        p = first["props"]
        scope = p.get("ctl_scope", "studio")
        n_obs += 1 if scope == "observe" else 0
        add("INFO", "Управление '%s' (%s, %s, подпись '%s', по умолчанию %s): %s." % (
            p.get("ctl_id"), p.get("ctl"), scope, p.get("ctl_title", p.get("ctl_id")), p.get("ctl_default", 0 if p.get("ctl") == "mech" else 1),
            ", ".join(o["name"] for o in lst)), first["id"])
    add("INFO", "Управляемых объектов: %d (Observe: %d)." % (len(controls), n_obs))
    for a in acts:
        if not a["name"].startswith(MECH_PREFIX):
            continue
        mid = a["name"][len(MECH_PREFIX):]
        fr = a.get("frames")
        stub = a.get("stub") or {}
        txt = "Заготовка MechanismConfig: id = &\"%s\", actuator = ANIM, anim_name = &\"%s\"" % (mid, a["name"])
        if stub.get("duration") is not None:
            txt += ", duration = %.2f" % stub["duration"]
        elif fr:
            txt += ", кадры %d..%d" % (fr[0], fr[1])
        if stub.get("kind") == "move":
            txt += " (сдвиг %.1f см по вектору Godot (%.2f, %.2f, %.2f); как SLIDE: axis = этот вектор, travel = %.1f)" % (stub["travel"], *stub["axis"], stub["travel"])
        elif stub.get("kind") == "rot":
            txt += " (поворот %.1f° вокруг вектора Godot (%.2f, %.2f, %.2f); как ROTATE: travel = %.1f)" % (stub["travel"], *stub["axis"], stub["travel"])
        add("INFO", txt + ".")
    return items


def summarize(items):
    e = sum(1 for lv, _, _ in items if lv == "ERROR")
    w = sum(1 for lv, _, _ in items if lv == "WARN")
    i = sum(1 for lv, _, _ in items if lv == "INFO")
    return e, w, i


def format_report(items):
    order = {"ERROR": 0, "WARN": 1, "INFO": 2}
    lines = ["[%s] %s" % (lv, tx) for lv, tx, _ in sorted(items, key=lambda x: order[x[0]])]
    e, w, i = summarize(items)
    lines.append("")
    lines.append("Итог: ERROR %d, WARN %d, INFO %d" % (e, w, i))
    return "\n".join(lines)


# ---------------------------------------------------------------- Blender: снимок сцены, помощники

DEFAULT_MODELS_DIR = r"D:\Godot\ec-project\data\models"
REF_COLLECTION = "EC_ref"
REPORT_TEXT = "EC_report"
PREFLIGHT_TEXT = "EC_preflight"

ROLE_PRESETS = [
    ("room", "room: корень комнаты (Empty)", ""),
    ("floor", "floor: группа пола", ""),
    ("shell", "shell: группа стен и штор", ""),
    ("ceiling", "ceiling: группа потолка", ""),
    ("decor_t1", "decor_t1: мебель", ""),
    ("decor_t2", "decor_t2: характер", ""),
    ("decor_t3", "decor_t3: мелочи", ""),
    ("fake_ao", "fake_ao: ложный AO", ""),
    ("collider", "collider: коллизия (прокси)", ""),
    ("window", "window: окно (прокси)", ""),
    ("door", "door: дверь (прокси)", ""),
    ("camera_bounds", "camera_bounds: границы камеры (прокси)", ""),
    ("room_volume", "room_volume: объём комнаты (прокси)", ""),
    ("table_origin", "table_origin: центр стола", ""),
    ("window_sun", "window_sun: луч окна", ""),
    ("sky_card", "sky_card: небо в окне", ""),
    ("bulb", "bulb: колба", ""),
    ("light", "light: якорь света", ""),
    ("mech_part", "mech_part: подвижная часть", ""),
    ("furniture", "furniture: мебель (метка)", ""),
    ("prop", "prop: предмет (метка)", ""),
]
PROXY_PRESETS = [(r, r, "") for r in PROXY_ROLES]

LAST = {"title": "", "text": "", "block": REPORT_TEXT, "lines": []}   # lines: [(ERROR|WARN|INFO|SUMMARY, текст)]


def role_of(obj):
    r = obj.get("role")
    return r if isinstance(r, str) else None


def depsgraph():
    return bpy.context.evaluated_depsgraph_get()


def world_bbox(obj):
    """(min, max) в мировых осях Blender с учётом модификаторов. Для пустышки точка"""
    from mathutils import Vector
    if obj.type not in {"MESH", "CURVE", "SURFACE", "META", "FONT"}:
        p = obj.matrix_world.translation.copy()
        return p, p.copy()
    ev = obj.evaluated_get(depsgraph())
    pts = [ev.matrix_world @ Vector(c) for c in ev.bound_box]
    lo = Vector((min(p[i] for p in pts) for i in range(3)))
    hi = Vector((max(p[i] for p in pts) for i in range(3)))
    return lo, hi


def tri_count(obj):
    if obj.type != "MESH":
        return 0
    ev = obj.evaluated_get(depsgraph())
    me = ev.to_mesh()
    try:
        me.calc_loop_triangles()
        return len(me.loop_triangles)
    finally:
        ev.to_mesh_clear()


def iter_fcurves(action):
    """fcurves действия: Blender до 4.3 хранит их в action.fcurves, с 4.4 в слоях, полосах и канальных мешках (5.0 убрал action.fcurves)"""
    fc = getattr(action, "fcurves", None)
    if fc is not None:
        yield from fc
        return
    for layer in getattr(action, "layers", []):
        for strip in layer.strips:
            for cb in getattr(strip, "channelbags", []):
                yield from cb.fcurves


def object_actions(obj):
    ad = obj.animation_data
    out = []
    if ad:
        if ad.action:
            out.append(ad.action)
        for tr in ad.nla_tracks:
            for st in tr.strips:
                if st.action and st.action not in out:
                    out.append(st.action)
    return out


def is_transparent(mat):
    if mat is None or mat.node_tree is None:
        return False
    for n in mat.node_tree.nodes:
        if n.type == "BSDF_PRINCIPLED":
            a = n.inputs.get("Alpha")
            if a is not None and (a.is_linked or a.default_value < 0.99):
                return True
    return False


def _py(v):
    """Значение Custom Property в обычный тип Python"""
    if isinstance(v, (str, int, float)):
        return v
    if hasattr(v, "to_list"):
        return v.to_list()
    if hasattr(v, "to_dict"):
        return v.to_dict()
    return str(v)


def _in_ref(obj):
    return any(c.name == REF_COLLECTION for c in obj.users_collection)


def _action_info(act, obj, fps):
    """Что реально движется в действии (канал с ключами без изменения не считается) и заготовка MechanismConfig"""
    kinds = set()
    scale_moved = False
    nonlinear = False
    ch = {"location": {}, "rot": {}}
    for fc in iter_fcurves(act):
        path = fc.data_path
        vals = [kp.co[1] for kp in fc.keyframe_points]
        moved = bool(vals) and (max(vals) - min(vals)) > 1e-4
        if path == "location" and moved:
            kinds.add("move")
        elif path.startswith("rotation") and moved:
            kinds.add("rot")
        elif path == "scale" and moved:
            scale_moved = True
        if any(kp.interpolation != "LINEAR" for kp in fc.keyframe_points):
            nonlinear = True
        if path == "location":
            ch["location"][fc.array_index] = fc
        elif path in ("rotation_euler", "rotation_quaternion"):
            ch["rot"][(path, fc.array_index)] = fc
    fr = act.frame_range
    info = {"name": act.name, "targets": [obj.name], "kinds": sorted(kinds), "scale_moved": scale_moved, "nonlinear": nonlinear,
            "frames": (int(fr[0]), int(fr[1])), "stub": None}
    try:
        duration = (fr[1] - fr[0]) / float(fps)
        if kinds == {"move"}:
            d = [ch["location"][i].evaluate(fr[1]) - ch["location"][i].evaluate(fr[0]) if i in ch["location"] else 0.0 for i in range(3)]
            ln = math.sqrt(sum(c * c for c in d))
            if ln > 1e-6:
                info["stub"] = {"kind": "move", "axis": to_godot([c / ln for c in d]), "travel": ln, "duration": duration}   # единицы Blender = см
        elif kinds == {"rot"}:
            from mathutils import Euler, Quaternion
            def at(frame):
                if any(k[0] == "rotation_euler" for k in ch["rot"]):
                    return Euler([ch["rot"][("rotation_euler", i)].evaluate(frame) if ("rotation_euler", i) in ch["rot"] else 0.0 for i in range(3)]).to_quaternion()
                return Quaternion([ch["rot"][("rotation_quaternion", i)].evaluate(frame) if ("rotation_quaternion", i) in ch["rot"] else (1.0 if i == 0 else 0.0) for i in range(4)])
            dq = at(fr[1]) @ at(fr[0]).inverted()
            axis, ang = dq.to_axis_angle()
            info["stub"] = {"kind": "rot", "axis": to_godot(list(axis)), "travel": math.degrees(ang), "duration": duration}
    except Exception:
        info["stub"] = None
    return info


def snapshot(scene):
    """Снимок сцены для check_room: корень комнаты и всё, что в него вложено (если корень один), иначе все объекты сцены, кроме эталонов EC_ref"""
    from mathutils import Vector
    objs = [o for o in scene.objects if not _in_ref(o)]
    rooms = [o for o in objs if role_of(o) == "room"]
    strays = []
    if len(rooms) == 1:
        root = rooms[0]
        take = [root] + list(root.children_recursive)
        names = {o.name for o in take}
        strays = [o.name for o in objs if o.parent is None and o.name not in names and o.type in {"MESH", "EMPTY"}]
    else:
        take = objs
    names = {o.name for o in take}
    nodes = []
    materials = {}
    images = {}
    for o in take:
        mw = o.matrix_world
        kind = o.type if o.type in ("MESH", "EMPTY", "CAMERA", "LIGHT") else "OTHER"
        d = {"id": o.name, "name": o.name, "parent": o.parent.name if (o.parent and o.parent.name in names) else None, "kind": kind,
             "props": {k: _py(o[k]) for k in o.keys() if not k.startswith("_")},
             "data_role": bool(o.type == "MESH" and o.data is not None and o.data.get("role") is not None),
             "pos": tuple(c * UNIT for c in mw.translation), "scale": tuple(o.matrix_basis.to_scale()), "rot_deg": math.degrees(o.matrix_basis.to_quaternion().angle),
             "aim": tuple((mw.to_3x3() @ Vector((0.0, 0.0, 1.0))).normalized()), "bbox": None, "tris": 0, "mats": []}
        if o.type == "MESH":
            lo, hi = world_bbox(o)
            d["bbox"] = (tuple(c * UNIT for c in lo), tuple(c * UNIT for c in hi))
            d["tris"] = tri_count(o)
            for sl in o.material_slots:
                mat = sl.material
                if mat is None:
                    continue
                d["mats"].append(mat.name)
                materials[mat.name] = {"transparent": is_transparent(mat)}
                if mat.node_tree:
                    for nd in mat.node_tree.nodes:
                        if nd.type == "TEX_IMAGE" and nd.image is not None:
                            images[nd.image.name] = {"name": nd.image.name, "w": int(nd.image.size[0]), "h": int(nd.image.size[1])}
        nodes.append(d)
    actions = {}
    for o in take:
        for act in object_actions(o):
            if act.name in actions:
                if o.name not in actions[act.name]["targets"]:
                    actions[act.name]["targets"].append(o.name)
            else:
                actions[act.name] = _action_info(act, o, scene.render.fps / scene.render.fps_base)
    return {"nodes": nodes, "materials": materials, "images": list(images.values()), "actions": list(actions.values()), "strays": strays,
            "extras_present": True}


def check(scene):
    """Проверка сцены Blender: единицы + check_room по снимку. [(level, text, node_id|None)]"""
    items = []
    us = scene.unit_settings
    if abs(us.scale_length - UNIT) > 1e-9:
        items.append(("ERROR", "Unit Scale = %.4f, нужен %.2f: 1 единица Blender = 1 см игры (комната 480 x 380 x 250 единиц), экспорт пишет числа как есть." % (us.scale_length, UNIT), None))
    if us.system != "METRIC":
        items.append(("WARN", "Единицы %s, нужны Metric." % us.system, None))
    items += check_room(snapshot(scene))
    return items


def find_root(scene):
    rooms = [o for o in scene.objects if role_of(o) == "room" and not _in_ref(o)]
    return rooms[0] if len(rooms) == 1 else None


def write_text(name, text):
    t = bpy.data.texts.get(name) or bpy.data.texts.new(name)
    t.clear()
    t.write(text)


def wrap_text(text, width):
    import textwrap
    return textwrap.wrap(text, width=max(20, int(width)), break_long_words=True, break_on_hyphens=False) or [""]


def parse_report_lines(text):
    out = []
    for ln in text.splitlines():
        m = re.match(r"^\[(ERROR|WARN|INFO)\]\s*(.*)$", ln)
        if m:
            out.append((m.group(1), m.group(2)))
        elif ln.startswith("Итог"):
            out.append(("SUMMARY", ln))
    return out


def copy_to_clipboard(text):
    """Копирует в буфер обмена. True, если после записи буфер не пуст (без окна, например в blender -b, буфер не работает)"""
    try:
        wm = bpy.context.window_manager
        wm.clipboard = text
        return wm.clipboard != ""
    except Exception:
        return False


def publish_report(title, text, block=REPORT_TEXT):
    """Отчёт виден везде: панель, окно, текстовый блок и буфер обмена. True, если скопирован в буфер"""
    LAST["title"] = title
    LAST["text"] = text
    LAST["block"] = block
    LAST["lines"][:] = parse_report_lines(text)
    write_text(block, text)
    return copy_to_clipboard(text)


def open_text_window(block_name):
    """Открывает текстовый блок в новом окне Blender (редактор Text, с переносом строк). True при успехе"""
    txt = bpy.data.texts.get(block_name)
    if txt is None:
        return False
    try:
        wm = bpy.context.window_manager
        before = set(wm.windows)
        bpy.ops.wm.window_new()
        new = [w for w in wm.windows if w not in before]
        if not new:
            return False
        area = new[0].screen.areas[0]
        area.type = "TEXT_EDITOR"
        space = area.spaces.active
        space.text = txt
        try:
            space.show_word_wrap = True
        except AttributeError:
            pass
        return True
    except Exception:
        return False


def draw_wrapped(layout, level, text, width):
    icon = {"ERROR": "ERROR", "WARN": "QUESTION", "INFO": "INFO"}.get(level, "NONE")
    col = layout.column(align=True)
    col.scale_y = 0.85
    col.alert = level == "ERROR"
    for k, part in enumerate(wrap_text(text, width)):
        col.label(text=part, icon=icon if k == 0 else "BLANK1")


def repo_root(start=None):
    """Корень репозитория (папка с project.godot): от start, от «Папки моделей» из панели или от файла .blend"""
    cands = []
    if start:
        cands.append(Path(start))
    try:
        md = bpy.context.scene.ec_room.models_dir
        if md:
            cands.append(Path(bpy.path.abspath(md)))
    except Exception:
        pass
    if bpy.data.filepath:
        cands.append(Path(bpy.data.filepath))
    for c in cands:
        try:
            c = c.resolve()
        except OSError:
            continue
        for d in [c] + list(c.parents):
            if (d / "project.godot").exists():
                return d
    return None


def preflight_path():
    cand = []
    try:
        cand.append(Path(__file__).resolve().parent.parent / "glb_preflight.py")
    except NameError:
        pass
    root = repo_root()
    if root:
        cand.append(root / "tools" / "glb_preflight.py")
    for c in cand:
        if c.exists():
            return c
    return None


def run_preflight_tool(glb):
    pf = preflight_path()
    if pf is None:
        return "tools/glb_preflight.py не найден: запустите проверку файла вручную (python tools/glb_preflight.py <файл> --kind room)."
    try:
        res = subprocess.run([sys.executable, str(pf), glb, "--kind", "room"], capture_output=True, text=True, encoding="utf-8", timeout=120)
        return res.stdout + res.stderr
    except (OSError, subprocess.SubprocessError) as e:
        return "Не удалось запустить glb_preflight.py: %s" % e


def models_dir_of(s):
    """Папка моделей игры: из настройки панели, иначе data/models найденного репозитория, иначе рядом с .blend"""
    md = getattr(s, "models_dir", "")
    if md:
        return Path(bpy.path.abspath(md))
    root = repo_root()
    if root:
        return root / "data" / "models"
    return Path(os.path.dirname(bpy.data.filepath) if bpy.data.filepath else os.getcwd())


def room_id_of(s):
    """Id модели комнаты: из панели, иначе имя файла .blend (room_<имя>)"""
    rid = (getattr(s, "room_id", "") or "").strip()
    if rid:
        return rid
    return Path(bpy.data.filepath).stem if bpy.data.filepath else "room_model"


def default_export_path(s):
    rid = room_id_of(s)
    return str(models_dir_of(s) / rid / (rid + ".glb"))


def resolve_export_path(raw, models_dir, rid):
    """Путь .glb из поля панели (без bpy). Пусто: <models_dir>/<rid>/<rid>.glb. Папка или путь без .glb: файл <папка>/<имя папки>.glb
    (одна папка на модель, как data/models/room_<имя>/room_<имя>.glb); голое имя: <models_dir>/<имя>/<имя>.glb"""
    raw = (raw or "").strip()
    if not raw:
        return str(Path(models_dir) / rid / (rid + ".glb"))
    p = Path(raw)
    if p.suffix.lower() == ".glb":
        return str(p)
    if str(p.parent) in ("", "."):
        return str(Path(models_dir) / p.name / (p.name + ".glb"))
    return str(p / (p.name + ".glb"))


def export_params(op, **wanted):
    """Оставляет только те параметры, которые есть у оператора в этой версии Blender"""
    names = {p.identifier for p in op.get_rna_type().properties}
    return {k: v for k, v in wanted.items() if k in names}


def do_export(scene, filepath, run_preflight=True):
    """Экспорт корня комнаты с потомками (прокси-коробки тоже: игра читает их и удаляет). Возвращает (ok, сообщение, отчёт)"""
    items = check(scene)
    if any(lv == "ERROR" for lv, _, _ in items):
        return False, "Экспорт остановлен: в проверке есть ERROR.", format_report(items)
    root = find_root(scene)
    view = bpy.context.view_layer
    prev_sel = [o for o in scene.objects if o.select_get()]
    prev_act = view.objects.active
    for o in scene.objects:
        o.select_set(False)
    for o in [root] + list(root.children_recursive):
        try:
            o.select_set(True)
        except RuntimeError:
            pass
    view.objects.active = root
    os.makedirs(os.path.dirname(filepath) or ".", exist_ok=True)
    wanted = dict(
        filepath=filepath, export_format="GLB", use_selection=True, export_apply=True, export_extras=True,
        export_cameras=False, export_lights=False, export_yup=True, export_animations=True,
        export_animation_mode="ACTIONS", export_force_sampling=False, export_skins=False, export_morph=False,
        export_draco_mesh_compression_enable=False, export_texcoords=True, export_normals=True, export_materials="EXPORT",
        export_image_format="AUTO", export_attributes=False,
        export_colors=True,   # Blender до 4.1: вершинные цвета включены
    )
    try:
        kw = export_params(bpy.ops.export_scene.gltf, **wanted, export_vertex_color="ACTIVE")   # Blender 4.2 и новее: Use Vertex Color
        try:
            bpy.ops.export_scene.gltf(**kw)
        except TypeError:   # значение перечисления не подошло этой версии: без него
            bpy.ops.export_scene.gltf(**export_params(bpy.ops.export_scene.gltf, **wanted))
    finally:
        for o in scene.objects:
            o.select_set(False)
        for o in prev_sel:
            try:
                o.select_set(True)
            except RuntimeError:
                pass
        view.objects.active = prev_act
    report = format_report(items)
    pre = run_preflight_tool(filepath) if run_preflight else ""
    if pre:
        report += "\n\n=== Проверка готового файла (glb_preflight) ===\n" + pre
    return True, "Экспортировано: %s" % filepath, report


def prepare_transforms(scene):
    """Меши: Apply All Transforms. Подвижные части и прокси: только Rotation и Scale (Location сохраняет origin шарнира и центр коробки).
    Объекты с детьми пропускаются (применение сдвинуло бы детей). Пустышки не трогаются"""
    root = find_root(scene)
    if root is None:
        return "Нужен ровно один объект с role = room"
    view = bpy.context.view_layer
    prev_sel = [o for o in scene.objects if o.select_get()]
    prev_act = view.objects.active
    problems = []
    keep_loc = set(PROXY_ROLES) | {"mech_part"}
    for o in root.children_recursive:
        if o.type != "MESH":
            continue
        if o.children:
            problems.append("%s: у объекта есть дети, трансформы не применены" % o.name)
            continue
        for x in scene.objects:
            x.select_set(False)
        o.select_set(True)
        view.objects.active = o
        try:
            if o.data.users > 1:
                bpy.ops.object.make_single_user(object=True, obdata=True)
            bpy.ops.object.transform_apply(location=role_of(o) not in keep_loc, rotation=True, scale=True)
        except RuntimeError as e:
            problems.append("%s: %s" % (o.name, e))
    for o in scene.objects:
        o.select_set(False)
    for o in prev_sel:
        o.select_set(True)
    view.objects.active = prev_act
    return "; ".join(problems) if problems else None


def _unique_name(base):
    if base not in bpy.data.objects:
        return base
    k = 1
    while "%s_%02d" % (base, k) in bpy.data.objects:
        k += 1
    return "%s_%02d" % (base, k)


def _link(obj, scene, root):
    coll = root.users_collection[0] if (root is not None and root.users_collection) else scene.collection
    coll.objects.link(obj)
    if root is not None:
        obj.parent = root
        obj.matrix_parent_inverse = root.matrix_world.inverted()


def make_box(scene, name, center, size, role=None):
    """Прокси-коробка: меш-куб без материала, отображение Wire, без поворота и масштаба, origin в центре"""
    hx, hy, hz = (c / 2.0 for c in size)
    verts = [(-hx, -hy, -hz), (hx, -hy, -hz), (hx, hy, -hz), (-hx, hy, -hz), (-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz)]
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.update()
    obj = bpy.data.objects.new(name, me)
    obj.location = center
    obj.display_type = "WIRE"
    if role:
        obj["role"] = role
    _link(obj, scene, find_root(scene))
    return obj


def make_refs(scene):
    """Эталон: стол 200 x 100 (верх на нуле) и пол на -50, размером с комнату по умолчанию (единицы Blender = см). Коллекция EC_ref, в экспорт не идёт"""
    coll = bpy.data.collections.get(REF_COLLECTION)
    if coll is None:
        coll = bpy.data.collections.new(REF_COLLECTION)
        scene.collection.children.link(coll)
    for nm in ("EC_ref_table", "EC_ref_floor"):
        o = bpy.data.objects.get(nm)
        if o is not None:
            bpy.data.objects.remove(o, do_unlink=True)
    for nm, size, center in (("EC_ref_table", (200.0, 100.0, 5.0), (0.0, 0.0, -2.5)), ("EC_ref_floor", (480.0, 380.0, 2.0), (0.0, 0.0, -51.0))):
        hx, hy, hz = (c / 2.0 for c in size)
        verts = [(-hx, -hy, -hz), (hx, -hy, -hz), (hx, hy, -hz), (-hx, hy, -hz), (-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz)]
        faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
        me = bpy.data.meshes.new(nm)
        me.from_pydata(verts, [], faces)
        me.update()
        o = bpy.data.objects.new(nm, me)
        o.location = center
        o.display_type = "WIRE"
        coll.objects.link(o)


def rotation_path(obj):
    return {"QUATERNION": "rotation_quaternion", "AXIS_ANGLE": "rotation_axis_angle"}.get(obj.rotation_mode, "rotation_euler")


def set_linear(act):
    for fc in iter_fcurves(act):
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"


def mech_key(scene, obj, mech_id, frame, rest):
    obj.keyframe_insert(data_path="location", frame=frame)
    obj.keyframe_insert(data_path=rotation_path(obj), frame=frame)
    act = obj.animation_data.action if obj.animation_data else None
    if act is None:
        return None
    if rest:
        act.name = MECH_PREFIX + mech_id
    set_linear(act)
    return act


def color_hex(c):
    """Цвет Blender (линейный RGB 0..1) в #rrggbb sRGB"""
    def enc(v):
        v = max(0.0, min(1.0, v))
        v = v * 12.92 if v <= 0.0031308 else 1.055 * (v ** (1 / 2.4)) - 0.055
        return int(round(v * 255))
    return "#%02x%02x%02x" % (enc(c[0]), enc(c[1]), enc(c[2]))


# ---------------------------------------------------------------- Blender: свойства, операторы, панель

if bpy is not None:
    from bpy.props import BoolProperty, EnumProperty, FloatProperty, FloatVectorProperty, IntProperty, PointerProperty, StringProperty

    class ECRoomSettings(bpy.types.PropertyGroup):
        room_id: StringProperty(name="Id модели", description="Имя файла и папки: room_test_01. Пусто: имя файла .blend", default="")
        models_dir: StringProperty(name="Папка моделей", description="Куда экспортировать: <папка>/<id>/<id>.glb (каталог data/models репозитория)",
                                   subtype="DIR_PATH", default=DEFAULT_MODELS_DIR)
        export_path: StringProperty(name="Файл .glb", description="Пусто: <Папка моделей>/<id>/<id>.glb", subtype="FILE_PATH", default="")
        role_preset: EnumProperty(name="Шаблон", items=ROLE_PRESETS, default="decor_t1")
        role: StringProperty(name="Роль", description="Custom Property role для выделенных объектов", default="")
        proxy_role: EnumProperty(name="Прокси", items=PROXY_PRESETS, default="collider")
        box_size: FloatVectorProperty(name="Размер, см", description="Размер прокси-коробки в единицах Blender (= см), когда ничего не выделено (центр в 3D-курсоре)", size=3,
                                      default=(100.0, 100.0, 100.0), min=1.0)
        ctl_kind: EnumProperty(name="Вид", items=[("toggle", "toggle: вкл/выкл", ""), ("slider", "slider: 0..1 (свет)", ""), ("mech", "mech: механизм", "")], default="toggle")
        ctl_id: StringProperty(name="ctl_id", description="Уникальный id управления, snake_case. У механизма равен <id> действия mech_<id>", default="")
        ctl_title: StringProperty(name="Подпись", description="ctl_title, русский допустим", default="")
        ctl_scope: EnumProperty(name="Где", items=[("studio", "только Room Studio", ""), ("observe", "Observe и студия", "")], default="studio")
        ctl_default: FloatProperty(name="По умолчанию", description="ctl_default 0..1", default=1.0, min=0.0, max=1.0)
        ctl_group: StringProperty(name="Группа", description="ctl_group: несколько объектов под одним управлением (необязательно)", default="")
        bulb_of: StringProperty(name="bulb_of", description="ctl_id (или ctl_group) лампы, с которой светится колба", default="")
        light_kind: EnumProperty(name="Свет", items=[("omni", "omni: точечный", ""), ("spot", "spot: прожектор", "")], default="omni")
        light_energy: FloatProperty(name="Энергия", description="light_energy, энергия Godot (100..250 для лампы на 120 см)", default=150.0, min=0.1)
        light_range: FloatProperty(name="Дальность, см", description="light_range в сантиметрах игры", default=400.0, min=1.0)
        light_angle: FloatProperty(name="Угол, °", description="light_angle у spot, градусы", default=60.0, min=1.0, max=89.0)
        light_color: FloatVectorProperty(name="Цвет", subtype="COLOR", size=3, min=0.0, max=1.0, default=(1.0, 0.95, 0.85))
        light_shadow: BoolProperty(name="Тень", description="light_shadow = 1 (не больше 2 ламп с тенью)", default=False)
        mech_id: StringProperty(name="Id механизма", description="Действие станет mech_<id>, объекту запишутся ctl = mech и ctl_id", default="curtain")
        mech_frames: IntProperty(name="Кадров хода", description="Длина хода механизма в кадрах (24 кадра = 1 с при 24 к/с)", default=24, min=2, max=600)
        wrap: IntProperty(name="Перенос строк", description="Ширина строки отчёта в панели, символов", default=46, min=24, max=200)
        show_info: BoolProperty(name="Показывать INFO", description="В панели показывать справочные строки (числа карточки, список управления); в окне и буфере они есть всегда", default=False)

    def settings(scene=None):
        return (scene or bpy.context.scene).ec_room

    class ECR_OT_check(bpy.types.Operator):
        bl_idname = "ecroom.check"
        bl_label = "Проверить комнату"
        bl_description = "Правила ATTN_25 §25.7.5. Отчёт в панели, буфере обмена и тексте EC_report"

        def execute(self, context):
            items = check(context.scene)
            text = format_report(items)
            copied = publish_report("Проверка комнаты", text, REPORT_TEXT)
            e, w, i = summarize(items)
            self.report({"ERROR"} if e else ({"WARNING"} if w else {"INFO"}),
                        "ERROR %d, WARN %d, INFO %d. %s" % (e, w, i, "Отчёт скопирован в буфер обмена" if copied else "Отчёт в тексте EC_report"))
            print(text)
            return {"FINISHED"}

    class ECR_OT_show_report(bpy.types.Operator):
        bl_idname = "ecroom.show_report"
        bl_label = "Показать отчёт"
        bl_description = "Весь последний отчёт крупным окном (без обрезки)"

        def invoke(self, context, event):
            try:
                return context.window_manager.invoke_props_dialog(self, width=900, confirm_text="Закрыть")
            except TypeError:
                return context.window_manager.invoke_props_dialog(self, width=900)

        def draw(self, context):
            lay = self.layout
            lay.label(text=LAST["title"] or "Отчёта ещё нет")
            order = {"ERROR": 0, "WARN": 1, "INFO": 2, "SUMMARY": 3}
            for lv, tx in sorted(LAST["lines"], key=lambda x: order[x[0]]):
                draw_wrapped(lay, lv, tx, 118)

        def execute(self, context):
            return {"FINISHED"}

    class ECR_OT_copy_report(bpy.types.Operator):
        bl_idname = "ecroom.copy_report"
        bl_label = "Копировать отчёт"
        bl_description = "Копирует весь последний отчёт в буфер обмена"

        def execute(self, context):
            if not LAST["text"]:
                self.report({"WARNING"}, "Отчёта ещё нет: нажмите «Проверить комнату»")
                return {"CANCELLED"}
            if copy_to_clipboard(LAST["text"]):
                self.report({"INFO"}, "Отчёт скопирован в буфер обмена (%d строк)" % len(LAST["text"].splitlines()))
                return {"FINISHED"}
            self.report({"WARNING"}, "Не удалось записать в буфер обмена: откройте отчёт кнопкой «В Text» и скопируйте из редактора")
            return {"CANCELLED"}

    class ECR_OT_open_report(bpy.types.Operator):
        bl_idname = "ecroom.open_report"
        bl_label = "Открыть в Text"
        bl_description = "Открывает последний отчёт в новом окне с редактором Text"

        def execute(self, context):
            if not LAST["text"]:
                self.report({"WARNING"}, "Отчёта ещё нет: нажмите «Проверить комнату»")
                return {"CANCELLED"}
            if open_text_window(LAST["block"]):
                return {"FINISHED"}
            self.report({"WARNING"}, "Окно не открылось. Отчёт в текстовом блоке %s: переключите любую область на Text Editor" % LAST["block"])
            return {"CANCELLED"}

    class ECR_OT_set_role(bpy.types.Operator):
        bl_idname = "ecroom.set_role"
        bl_label = "Назначить роль выделенным"
        bl_description = "Записывает Custom Property role на выделенные объекты (на объект, не на данные меша)"
        use_preset: BoolProperty(default=False)

        def execute(self, context):
            s = settings(context.scene)
            role = s.role_preset if self.use_preset else s.role.strip()
            if not ROLE_RE.match(role or ""):
                self.report({"ERROR"}, "Роль '%s' не подходит: a-z, 0-9, _, начинается с буквы" % role)
                return {"CANCELLED"}
            n = 0
            for o in context.selected_objects:
                o["role"] = role
                n += 1
            self.report({"INFO"}, "role = %s у %d объектов" % (role, n))
            return {"FINISHED"}

    class ECR_OT_clear_role(bpy.types.Operator):
        bl_idname = "ecroom.clear_role"
        bl_label = "Удалить роль"
        bl_description = "Удаляет role у выделенных объектов (и с данных меша, если роль попала туда по ошибке)"

        def execute(self, context):
            n = 0
            for o in context.selected_objects:
                hit = False
                if "role" in o.keys():
                    del o["role"]
                    hit = True
                data = getattr(o, "data", None)
                if data is not None and hasattr(data, "keys") and "role" in data.keys():
                    del data["role"]
                    hit = True
                n += 1 if hit else 0
            self.report({"INFO"}, "Роль удалена у %d объектов" % n)
            return {"FINISHED"}

    class ECR_OT_set_props(bpy.types.Operator):
        bl_idname = "ecroom.set_props"
        bl_label = "Записать свойства"
        bl_description = "Пишет свойства из панели на выделенные объекты: управление (ctl_*), свет (light_*) или колбу (bulb_of)"
        what: EnumProperty(items=[("CTL", "ctl", ""), ("LIGHT", "light", ""), ("BULB", "bulb", "")], default="CTL")

        def execute(self, context):
            s = settings(context.scene)
            sel = list(context.selected_objects)
            if not sel:
                self.report({"ERROR"}, "Выделите объекты")
                return {"CANCELLED"}
            if self.what == "CTL":
                cid = s.ctl_id.strip()
                if not ROLE_RE.match(cid):
                    self.report({"ERROR"}, "ctl_id '%s': a-z, 0-9, _, начинается с буквы" % cid)
                    return {"CANCELLED"}
                if s.ctl_group.strip() and not ROLE_RE.match(s.ctl_group.strip()):
                    self.report({"ERROR"}, "Группа: a-z, 0-9, _, начинается с буквы")
                    return {"CANCELLED"}
                for o in sel:
                    o["ctl"] = s.ctl_kind
                    o["ctl_id"] = cid
                    o["ctl_scope"] = s.ctl_scope
                    o["ctl_default"] = float(s.ctl_default) if s.ctl_kind != "toggle" else int(s.ctl_default > 0.0)
                    if s.ctl_title.strip():
                        o["ctl_title"] = s.ctl_title.strip()
                    if s.ctl_group.strip():
                        o["ctl_group"] = s.ctl_group.strip()
                    elif "ctl_group" in o.keys():
                        del o["ctl_group"]
            elif self.what == "LIGHT":
                for o in sel:
                    o["role"] = "light"
                    o["light_kind"] = s.light_kind
                    o["light_energy"] = float(s.light_energy)
                    o["light_range"] = float(s.light_range)
                    if s.light_kind == "spot":
                        o["light_angle"] = float(s.light_angle)
                    elif "light_angle" in o.keys():
                        del o["light_angle"]
                    o["light_color"] = color_hex(s.light_color)
                    o["light_shadow"] = 1 if s.light_shadow else 0
            else:
                if not ROLE_RE.match(s.bulb_of.strip() or ""):
                    self.report({"ERROR"}, "bulb_of: ctl_id лампы (a-z, 0-9, _)")
                    return {"CANCELLED"}
                for o in sel:
                    o["role"] = "bulb"
                    o["bulb_of"] = s.bulb_of.strip()
            self.report({"INFO"}, "Записано на %d объектов" % len(sel))
            return {"FINISHED"}

    class ECR_OT_clear_ctl(bpy.types.Operator):
        bl_idname = "ecroom.clear_ctl"
        bl_label = "Убрать управление"
        bl_description = "Удаляет ctl, ctl_id, ctl_title, ctl_scope, ctl_default, ctl_group у выделенных объектов"

        def execute(self, context):
            n = 0
            for o in context.selected_objects:
                for k in ("ctl", "ctl_id", "ctl_title", "ctl_scope", "ctl_default", "ctl_group"):
                    if k in o.keys():
                        del o[k]
                        n += 1
            self.report({"INFO"}, "Удалено свойств: %d" % n)
            return {"FINISHED"}

    class ECR_OT_light_anchor(bpy.types.Operator):
        bl_idname = "ecroom.light_anchor"
        bl_label = "Создать якорь света"
        bl_description = "Пустышка-стрелка в 3D-курсоре, повёрнута вниз: свет идёт по стрелке. Свойства light_* из панели; при заданном ctl_id пишется и управление"

        def execute(self, context):
            s = settings(context.scene)
            scene = context.scene
            name = _unique_name(s.ctl_id.strip() if ROLE_RE.match(s.ctl_id.strip() or "") else "lamp")
            o = bpy.data.objects.new(name, None)
            o.empty_display_type = "SINGLE_ARROW"
            o.empty_display_size = 0.3
            o.location = scene.cursor.location
            o.rotation_euler = (math.pi, 0.0, 0.0)   # стрелка (+Z) вниз
            _link(o, scene, find_root(scene))
            o["role"] = "light"
            o["light_kind"] = s.light_kind
            o["light_energy"] = float(s.light_energy)
            o["light_range"] = float(s.light_range)
            if s.light_kind == "spot":
                o["light_angle"] = float(s.light_angle)
            o["light_color"] = color_hex(s.light_color)
            o["light_shadow"] = 1 if s.light_shadow else 0
            if ROLE_RE.match(s.ctl_id.strip() or ""):
                o["ctl"] = "slider" if s.ctl_kind == "slider" else "toggle"
                o["ctl_id"] = s.ctl_id.strip()
                o["ctl_scope"] = s.ctl_scope
                o["ctl_default"] = 1
                if s.ctl_title.strip():
                    o["ctl_title"] = s.ctl_title.strip()
                if s.ctl_group.strip():
                    o["ctl_group"] = s.ctl_group.strip()
            for x in scene.objects:
                x.select_set(False)
            o.select_set(True)
            context.view_layer.objects.active = o
            self.report({"INFO"}, "Якорь '%s' создан" % o.name)
            return {"FINISHED"}

    class ECR_OT_proxy(bpy.types.Operator):
        bl_idname = "ecroom.proxy"
        bl_label = "Прокси-коробка"
        bl_description = "Коробка (Wire, без материала) вокруг выделенных объектов; без выделения: по размеру (см) из панели в 3D-курсоре. Роль из списка «Прокси»"

        def execute(self, context):
            s = settings(context.scene)
            scene = context.scene
            sel = [o for o in context.selected_objects if o.type == "MESH" and role_of(o) not in PROXY_ROLES]
            if sel:
                los, his = zip(*(world_bbox(o) for o in sel))
                lo = [min(l[i] for l in los) for i in range(3)]
                hi = [max(h[i] for h in his) for i in range(3)]
                center = tuple((lo[i] + hi[i]) / 2.0 for i in range(3))
                size = tuple(max(hi[i] - lo[i], 1.0) for i in range(3))
            else:
                center = tuple(scene.cursor.location)
                size = tuple(s.box_size)
            o = make_box(scene, _unique_name(s.proxy_role), center, size, s.proxy_role)
            for x in scene.objects:
                x.select_set(False)
            o.select_set(True)
            context.view_layer.objects.active = o
            self.report({"INFO"}, "Прокси '%s': %.0f x %.0f x %.0f см" % (o.name, *size))
            return {"FINISHED"}

    class ECR_OT_prepare(bpy.types.Operator):
        bl_idname = "ecroom.prepare"
        bl_label = "Применить трансформы"
        bl_description = "Меши: Apply All Transforms. Подвижные части и прокси: только Rotation и Scale. Пустышки и объекты с детьми не трогаются"

        def execute(self, context):
            err = prepare_transforms(context.scene)
            if err:
                self.report({"ERROR"}, err)
                return {"CANCELLED"}
            self.report({"INFO"}, "Трансформы применены")
            return {"FINISHED"}

    class ECR_OT_refs(bpy.types.Operator):
        bl_idname = "ecroom.refs"
        bl_label = "Эталон: стол и пол"
        bl_description = "Стол 200 x 100 см (верх на нуле) и пол на -50 (коллекция EC_ref, в экспорт не идёт): сверка размеров мебели и нуля комнаты"

        def execute(self, context):
            make_refs(context.scene)
            self.report({"INFO"}, "Эталон создан (коллекция %s)" % REF_COLLECTION)
            return {"FINISHED"}

    class ECR_OT_mech_key(bpy.types.Operator):
        bl_idname = "ecroom.mech_key"
        bl_label = "Ключ механизма"
        bl_description = "Покой: ключ на кадре 1, имя mech_<id>, объекту пишутся ctl = mech и ctl_id. Рабочее: ключ на кадре 1 + длина хода (сначала сдвиньте деталь)"
        rest: BoolProperty(default=True)

        def execute(self, context):
            obj = context.active_object
            s = settings(context.scene)
            if obj is None:
                self.report({"ERROR"}, "Выберите подвижную часть")
                return {"CANCELLED"}
            if not ROLE_RE.match(s.mech_id):
                self.report({"ERROR"}, "Id механизма: a-z, 0-9, _")
                return {"CANCELLED"}
            frame = 1 if self.rest else 1 + s.mech_frames
            if mech_key(context.scene, obj, s.mech_id, frame, self.rest) is None:
                self.report({"ERROR"}, "Ключ не создан")
                return {"CANCELLED"}
            if self.rest:
                if role_of(obj) is None:
                    obj["role"] = "mech_part"
                obj["ctl"] = "mech"
                obj["ctl_id"] = s.mech_id
                if "ctl_scope" not in obj.keys():
                    obj["ctl_scope"] = "studio"
                if "ctl_default" not in obj.keys():
                    obj["ctl_default"] = 0
            else:
                context.scene.frame_end = max(context.scene.frame_end, frame)
            self.report({"INFO"}, "Ключ на кадре %d (%s)" % (frame, "покой" if self.rest else "рабочее положение"))
            return {"FINISHED"}

    class ECR_OT_export(bpy.types.Operator):
        bl_idname = "ecroom.export"
        bl_label = "Экспорт .glb"
        bl_description = "Проверка, экспорт корня комнаты с потомками и проверка готового файла (glb_preflight --kind room). Отчёт в панели, буфере обмена и тексте EC_preflight"

        def execute(self, context):
            s = settings(context.scene)
            path = resolve_export_path(bpy.path.abspath(s.export_path) if s.export_path else "", models_dir_of(s), room_id_of(s))
            ok, msg, rep = do_export(context.scene, path)
            copied = publish_report("Экспорт: " + msg, (msg + "\n\n" + rep) if rep else msg, PREFLIGHT_TEXT)
            print(msg)
            print(rep)
            self.report({"INFO"} if ok else {"ERROR"}, msg + (". Отчёт скопирован в буфер обмена" if copied else ""))
            return {"FINISHED"} if ok else {"CANCELLED"}

    class ECR_PT_panel(bpy.types.Panel):
        bl_label = "EC Room: комната для игры"
        bl_idname = "ECR_PT_panel"
        bl_space_type = "VIEW_3D"
        bl_region_type = "UI"
        bl_category = "EC Room"

        def draw(self, context):
            lay = self.layout
            s = settings(context.scene)
            lay.prop(s, "room_id")
            lay.operator("ecroom.check", icon="CHECKMARK")

            box = lay.box()
            box.label(text="1. Роли и свойства")
            box.prop(s, "role_preset", text="")
            op = box.operator("ecroom.set_role", text="Назначить из шаблона")
            op.use_preset = True
            box.prop(s, "role")
            op = box.operator("ecroom.set_role", text="Назначить свою")
            op.use_preset = False
            box.operator("ecroom.clear_role", icon="X")
            sub = box.box()
            sub.label(text="Управление (ctl_*)")
            sub.prop(s, "ctl_kind")
            sub.prop(s, "ctl_id")
            sub.prop(s, "ctl_title")
            sub.prop(s, "ctl_scope")
            sub.prop(s, "ctl_default")
            sub.prop(s, "ctl_group")
            op = sub.operator("ecroom.set_props", text="Записать управление")
            op.what = "CTL"
            sub.operator("ecroom.clear_ctl", icon="X")
            sub = box.box()
            sub.label(text="Свет (якорь, длины в см)")
            sub.prop(s, "light_kind")
            sub.prop(s, "light_energy")
            sub.prop(s, "light_range")
            if s.light_kind == "spot":
                sub.prop(s, "light_angle")
            sub.prop(s, "light_color")
            sub.prop(s, "light_shadow")
            sub.operator("ecroom.light_anchor", icon="LIGHT_POINT")
            op = sub.operator("ecroom.set_props", text="Свет: записать выделенным")
            op.what = "LIGHT"
            sub = box.box()
            sub.label(text="Колба")
            sub.prop(s, "bulb_of")
            op = sub.operator("ecroom.set_props", text="Колба: записать выделенным")
            op.what = "BULB"

            box = lay.box()
            box.label(text="2. Подготовка")
            box.operator("ecroom.prepare", icon="OBJECT_ORIGIN")
            box.prop(s, "proxy_role")
            box.prop(s, "box_size")
            box.operator("ecroom.proxy", icon="MESH_CUBE")
            box.operator("ecroom.refs", icon="MESH_PLANE")

            box = lay.box()
            box.label(text="3. Механизм (анимация)")
            box.prop(s, "mech_id")
            box.prop(s, "mech_frames")
            row = box.row(align=True)
            op = row.operator("ecroom.mech_key", text="Ключ: покой")
            op.rest = True
            op = row.operator("ecroom.mech_key", text="Ключ: рабочее")
            op.rest = False

            box = lay.box()
            box.label(text="4. Экспорт")
            box.prop(s, "models_dir")
            box.prop(s, "export_path")
            box.operator("ecroom.export", icon="EXPORT")

            if LAST["text"]:
                box = lay.box()
                box.label(text=LAST["title"] or "Последний отчёт")
                row = box.row(align=True)
                row.operator("ecroom.show_report", text="Показать", icon="TEXT")
                row.operator("ecroom.copy_report", text="Копировать", icon="COPYDOWN")
                row.operator("ecroom.open_report", text="В Text", icon="WINDOW")
                col = box.column(align=True)
                col.prop(s, "wrap")
                col.prop(s, "show_info")
                order = {"ERROR": 0, "WARN": 1, "INFO": 2, "SUMMARY": 3}
                for lv, tx in sorted(LAST["lines"], key=lambda x: order[x[0]]):
                    if lv == "INFO" and not s.show_info:
                        continue
                    draw_wrapped(box, lv, tx, s.wrap)

    CLASSES = (ECRoomSettings, ECR_OT_check, ECR_OT_show_report, ECR_OT_copy_report, ECR_OT_open_report, ECR_OT_set_role, ECR_OT_clear_role,
               ECR_OT_set_props, ECR_OT_clear_ctl, ECR_OT_light_anchor, ECR_OT_proxy, ECR_OT_prepare, ECR_OT_refs, ECR_OT_mech_key, ECR_OT_export, ECR_PT_panel)

    def register():
        for c in CLASSES:
            bpy.utils.register_class(c)
        bpy.types.Scene.ec_room = PointerProperty(type=ECRoomSettings)

    def unregister():
        del bpy.types.Scene.ec_room
        for c in reversed(CLASSES):
            bpy.utils.unregister_class(c)


# ---------------------------------------------------------------- командная строка

def _cli(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="ec_room_tools")
    ap.add_argument("cmd", choices=["check", "export"])
    ap.add_argument("--id", default="")
    ap.add_argument("--models-dir", default=DEFAULT_MODELS_DIR, help="папка моделей игры (по умолчанию %s)" % DEFAULT_MODELS_DIR)
    ap.add_argument("--out", default="", help="путь .glb (по умолчанию <папка моделей>/<id>/<id>.glb)")
    a = ap.parse_args(argv)
    scene = bpy.context.scene
    if a.cmd == "check":
        items = check(scene)
        print(format_report(items))
        return 1 if any(lv == "ERROR" for lv, _, _ in items) else 0
    class _S:  # минимальная замена настроек панели; id по умолчанию берётся из имени файла .blend
        room_id, models_dir = a.id, a.models_dir
    path = resolve_export_path(a.out, models_dir_of(_S), room_id_of(_S))
    ok, msg, rep = do_export(scene, path)
    print(msg)
    print(rep)
    return 0 if ok else 1


if __name__ == "__main__" and bpy is not None:
    if "--" in sys.argv and bpy.app.background:
        sys.exit(_cli(sys.argv[sys.argv.index("--") + 1:]))
    register()
