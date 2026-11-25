"""ec_model_tools: помощник Blender для экспорта моделей в ec-project (0_ATTN_24, шпаргалка: tools/blender/CHEATSHEET.md).

Как пользоваться
  1. В Blender открыть вкладку Scripting, Open, выбрать этот файл, Run Script. В 3D-окне справа (клавиша N) появится вкладка «EC».
     Постоянно: Edit, Preferences, Add-ons, Install from Disk, выбрать этот файл (Blender 4.2 и новее покажет предупреждение про legacy-аддон: это нормально).
  2. Без интерфейса (проверка перед коммитом):
        blender -b art/blender/wagon_04.blend -P tools/blender/ec_model_tools.py -- check
        blender -b art/blender/wagon_04.blend -P tools/blender/ec_model_tools.py -- export --id wagon_04
     Код возврата 1, если проверка нашла ошибки.

Что делает
  Проверка: берёт кузов (объект с Custom Property role = body) и всё, что в него вложено, и сверяет с правилами 0_ATTN_24 §24.3, §24.4:
  роли, имена, масштаб и поворот, материалы (paint_*), UV и UV2, треугольники, анимации mech_*, метка Z=0 (ось буферов), стандартная высота буферов.
  Помощники: назначить роль, применить трансформы правильно (кузов целиком, детали только поворот и масштаб), эталон «рельс и колёса»,
  ключи покоя и рабочего положения механизма.
  Экспорт: glb с нужными настройками (свойства оператора подбираются под версию Blender), затем tools/glb_preflight.py по готовому файлу.
Из Blender ничего не пишется в репозиторий, кроме самого .glb.
"""
bl_info = {
    "name": "EC model tools",
    "author": "ec-project",
    "version": (1, 1, 0),
    "blender": (4, 2, 0),
    "location": "3D Viewport > Sidebar (N) > EC",
    "description": "Проверка и экспорт моделей вагонов, локомотивов и зданий для ec-project",
    "category": "Import-Export",
}

import math
import os
import re
import subprocess
import sys
from pathlib import Path

import bpy
from bpy.props import BoolProperty, EnumProperty, FloatProperty, IntProperty, PointerProperty, StringProperty
from mathutils import Matrix, Vector

# ---- Правила (держать в синхроне с tools/glb_preflight.py и 0_ATTN_24 §24.4) ----
ROLE_RE = re.compile(r"^[a-z][a-z0-9_]*$")
DUP_SUFFIX = re.compile(r"[.]\d{3,}$")
DEFAULT_NAMES = re.compile(r"^(Cube|Plane|Sphere|Cylinder|Cone|Torus|Circle|Empty|Suzanne|Light|Camera|Icosphere|Grid)(\.\d+)?$", re.I)
DEBUG_NAMES = {"sphere", "frontmarker", "ax", "ay", "az", "marker"}
MAT_PREFIXES = ("paint_", "trim_", "glass_", "emit_", "rubber_", "metal_")
TRI_BUDGET = {"trains": 50000, "buildings": 30000}
# NEM 303 «Puffer» (2015), H0: высота середины буфера 12.2 ±0.5 мм, расстояние между осями 20.0 ±0.2 мм, нижняя кромка тарелки не ниже 9.6 мм.
# В единицах игры (1 единица = 1 м прототипа, 1:87): 1.061 ±0.043, 1.74, 0.835
BUFFER_H = 1.061
BUFFER_TOL = 0.043
BUFFER_SPACING = 1.74
BUFFER_SPACING_TOL = 0.035
BUFFER_UMIN = 0.835
# Рабочие папки автора (меняются в панели): исходники .blend и каталог моделей игры
DEFAULT_ART_DIR = r"E:\GodotCopy\Blender\Art"
DEFAULT_MODELS_DIR = r"D:\Godot\ec-project\data\models"
# Эталон пути: колея между внутренними гранями рельсов 1.65, рельс-бокс 0.1 x 25 x 0.25 (вместе 1.85 по ширине), толщина колеса
GAUGE = 1.65
RAIL_W = 0.1
RAIL_LEN = 25.0
RAIL_H = 0.25
WHEEL_T = 0.12
AXLE_R = 0.07
REF_COLLECTION = "EC_ref"
SRC_COLLECTION = "SRC"   # исходная иерархия чужой модели: не проверяется и не экспортируется
REPORT_TEXT = "EC_report"
PREFLIGHT_TEXT = "EC_preflight"

ROLE_PRESETS = [
    ("body", "body: кузов (корень)", ""),
    ("door_l", "door_l: дверь левая", ""),
    ("door_r", "door_r: дверь правая", ""),
    ("hatch_1", "hatch_1: люк", ""),
    ("pantograph_1", "pantograph_1: пантограф", ""),
    ("fan_1", "fan_1: вентилятор", ""),
    ("buffer_1", "buffer_1: ось буфера", ""),
    ("buffer_2", "buffer_2: ось буфера", ""),
    ("buffer_3", "buffer_3: ось буфера", ""),
    ("buffer_4", "buffer_4: ось буфера", ""),
    ("headlight_front", "headlight_front: фара передняя (белая)", ""),
    ("headlight_rear", "headlight_rear: фара задняя (красная)", ""),
    ("cab_light", "cab_light: свет кабины", ""),
    ("unit_1", "unit_1: узел тележки (группа осей, пустышка)", ""),
    ("wheel_1_1", "wheel_1_1: колёсная пара узла 1", ""),
    ("frame_1", "frame_1: рама узла 1", ""),
]

# Последний отчёт: панель, крупное окно, редактор Text и буфер обмена берут его отсюда
LAST = {"title": "", "text": "", "block": REPORT_TEXT, "lines": []}  # lines: [(ERROR|WARN|INFO|SUMMARY, текст)]


# ---------------------------------------------------------------- общее

def settings(scene=None):
    return (scene or bpy.context.scene).ec_tools


def role_of(obj):
    r = obj.get("role")
    return r if isinstance(r, str) else None


def find_body(scene):
    bodies = [o for o in scene.objects if role_of(o) == "body"]
    return bodies


def export_set(body):
    """Кузов и все вложенные объекты, которые участвуют в экспорте"""
    return [body] + list(body.children_recursive)


def depsgraph():
    return bpy.context.evaluated_depsgraph_get()


def world_bbox(obj):
    """(min, max) в мировых осях Blender с учётом модификаторов. Для пустышки точка"""
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


def repo_root(start=None):
    """Корень репозитория (папка с project.godot): от start, от «Папки моделей» из панели или от файла .blend"""
    cands = []
    if start:
        cands.append(Path(start))
    try:
        md = bpy.context.scene.ec_tools.models_dir
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


def check_model(scene, buffer_h=BUFFER_H, kind="trains", brush=False):
    """Возвращает список (level, text, object_name|None). level: ERROR, WARN, INFO"""
    out = []

    def add(level, text, obj=None):
        out.append((level, text, obj.name if obj else None))

    bodies = find_body(scene)
    if len(bodies) != 1:
        add("ERROR", "Объектов с Custom Property role = body: %d, нужен ровно один (кузов)." % len(bodies))
        return out
    body = bodies[0]
    objs = export_set(body)

    if body.parent is not None:
        add("ERROR", "Кузов (body) не должен иметь родителя: он корень модели.", body)
    if body.type != "MESH":
        add("ERROR", "Кузов (body) должен быть мешем, сейчас %s." % body.type, body)

    # корневые объекты рядом с кузовом (кроме эталонов EC_ref)
    for o in scene.objects:
        if o.parent is None and o is not body and o.type in {"MESH", "EMPTY"} and not o.name.startswith("EC_ref"):
            col_names = {c.name for c in o.users_collection}
            if REF_COLLECTION in col_names or SRC_COLLECTION in col_names:
                continue
            add("WARN", "Объект '%s' лежит рядом с кузовом и не войдёт в экспорт. Если он нужен, сделайте его потомком кузова; если это эталон, переименуйте EC_ref_*." % o.name, o)

    # ---- роли, имена ----
    roles = {}
    for o in objs:
        r = role_of(o)
        if o.get("role") is not None and r is None:
            add("ERROR", "Объект '%s': role должна быть строкой." % o.name, o)
        if o.type == "MESH" and o.data is not None and o.data.get("role") is not None:
            add("ERROR", "Объект '%s': role стоит на данных меша (Object Data), а нужна на объекте (вкладка Object, Custom Properties): иначе игра роль не увидит." % o.name, o)
        if r:
            if not ROLE_RE.match(r):
                add("ERROR", "Объект '%s': роль '%s': только a-z, 0-9, _, начинается с буквы." % (o.name, r), o)
            roles.setdefault(r, []).append(o)
        nm = o.name
        if DUP_SUFFIX.search(nm):
            add("WARN", "Объект '%s': хвост дубля (.001). Id зоны покраски строится из имени узла; переименуйте." % nm, o)
        if " " in nm:
            add("WARN", "Объект '%s': пробел в имени, используйте _." % nm, o)
        if DEFAULT_NAMES.match(nm):
            add("WARN", "Объект '%s': имя по умолчанию, дайте осмысленное." % nm, o)
        if nm.lower() in DEBUG_NAMES:
            add("WARN", "Объект '%s': отладочный, в рабочую модель не экспортируется." % nm, o)
        if o.type in {"CAMERA", "LIGHT"}:
            add("WARN", "Объект '%s' (%s) внутри модели: камеры и свет не экспортируются, свет задаётся LightConfig в Godot." % (nm, o.type), o)
    for r, lst in roles.items():
        if len(lst) > 1:
            add("WARN", "Роль '%s' у %d объектов (%s): игра возьмёт первый. Для пар _l/_r, _1/_2." % (r, len(lst), ", ".join(o.name for o in lst)))

    # ---- трансформы ----
    for o in objs:
        sc = o.matrix_basis.to_scale()
        if any(abs(c - 1.0) > 1e-4 for c in sc):
            add("ERROR", "Объект '%s': масштаб (%.3f, %.3f, %.3f). Нажмите «Применить трансформы» или Ctrl+A, Scale." % (o.name, *sc), o)
        ang = math.degrees(o.matrix_basis.to_quaternion().angle)
        if ang > 0.01:
            add("ERROR" if o is body else "WARN", "Объект '%s': поворот в покое %.2f°. Для оси механизма и кузова нужен Apply Rotation." % (o.name, ang), o)
    if body.matrix_world.translation.length > 1e-3:
        add("WARN", "Кузов смещён от начала координат мира (%.3f, %.3f, %.3f): нулевая точка модели должна быть в центре кузова на оси буферов." %
            tuple(body.matrix_world.translation), body)

    # ---- габарит и метка Z=0 ----
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    meshes = [o for o in objs if o.type == "MESH"]
    for o in meshes:
        a, b = world_bbox(o)
        for i in range(3):
            lo[i] = min(lo[i], a[i])
            hi[i] = max(hi[i], b[i])
    if meshes:
        length, width, height = hi[1] - lo[1], hi[0] - lo[0], hi[2] - lo[2]
        cx, cy = (hi[0] + lo[0]) / 2.0, (hi[1] + lo[1]) / 2.0
        add("INFO", "Габарит: длина (Y) %.3f, ширина (X) %.3f, высота (Z) %.3f; Z от %.3f до %.3f. Для паспорта: coupler_offset около %.2f." %
            (length, width, height, lo[2], hi[2], length / 2.0))
        if abs(cx) > 0.05 or abs(cy) > 0.05:
            add("WARN", "Центр габарита смещён от нуля: X %.3f, Y %.3f. Origin кузова должен быть в центре по длине и ширине." % (cx, cy), body)
        if lo[2] < -buffer_h - FLANGE_DEPTH:
            add("WARN", "Низ модели Z=%.3f ниже головки рельса (рельс на Z=%.3f при метке Z=0 на оси буферов; реборды колёс уходят ниже головки до %.2f, это допустимо)." %
                (lo[2], -buffer_h, FLANGE_DEPTH), body)
        if length < 3.0 or length > 40.0:
            add("WARN", "Длина %.2f вне ожидаемых 3..40: проверьте масштаб (Unit Scale 1.0, 1 единица = 1 м прототипа)." % length, body)
        if kind == "trains" and width > 4.5:
            add("WARN", "Ширина %.2f велика для подвижного состава: проверьте масштаб." % width, body)
        add("INFO", "Метка Z=0 это ось буферов; рельс на Z=%.3f. Нос модели смотрит в +Y. В паспорте offset_mesh_y = %.3f." % (-buffer_h, buffer_h))
        add("INFO", "Коллизия кузова (BoxShape3D): size = (%.3f, %.3f, %.3f), position = (%.3f, %.3f, %.3f) в осях Godot." %
            (width, height, length, cx, (hi[2] + lo[2]) / 2.0, -cy))

    # ---- узлы тележек и колёсные пары: unit_<n> (пустышка) с детьми wheel_<n>_<k> и свойством radius ----
    units = [o for o in objs if UNIT_RE.match(role_of(o) or "")]
    wheels = [o for o in objs if WHEEL_ROLE_RE.match(role_of(o) or "")]
    inv_b = body.matrix_world.inverted()
    for w in wheels:
        par = w.parent
        if par is None or not UNIT_RE.match(role_of(par) or ""):
            add("ERROR", "Колёсная пара '%s' (role %s): родителем должен быть узел unit_<n>." % (w.name, role_of(w)), w)
        rad = w.get("radius")
        if isinstance(rad, bool) or not isinstance(rad, (int, float)) or rad <= 0:
            add("ERROR", "Колёсная пара '%s': нет свойства radius (число больше 0: радиус круга катания). Его ставит кнопка «Узел из выделенных колёс»." % w.name, w)
            continue
        if not 0.2 <= rad <= 1.5:
            add("WARN", "Колёсная пара '%s': radius %.3f вне ожидаемых 0.2..1.5 (единицы = метры прототипа)." % (w.name, rad), w)
        pw = (inv_b @ w.matrix_world).translation
        if abs(pw.z - (rad - buffer_h)) > 0.02:
            add("WARN", "Колёсная пара '%s': origin на Z=%.3f, а по радиусу %.3f центр оси должен быть на Z=%.3f (радиус минус высота буферов). Проверьте origin и положение." %
                (w.name, pw.z, rad, rad - buffer_h), w)
        if abs(pw.x) > 0.02:
            add("WARN", "Колёсная пара '%s': origin смещён по X на %.3f, пара должна стоять по центру колеи." % (w.name, pw.x), w)
    for u in units:
        if u.type != "EMPTY":
            add("WARN", "Узел '%s' (role %s) должен быть пустышкой." % (u.name, role_of(u)), u)
        kids = [w for w in wheels if w.parent is u]
        if not kids:
            add("WARN", "Узел '%s' без колёсных пар: детьми нужны объекты с ролью wheel_<n>_<k>." % u.name, u)
            continue
        rs = [w.get("radius") for w in kids if isinstance(w.get("radius"), (int, float)) and not isinstance(w.get("radius"), bool)]
        ys = [(inv_b @ w.matrix_world).translation.y for w in kids]
        up = (inv_b @ u.matrix_world).translation
        c, offs, _ = unit_layout(ys)
        if rs and max(rs) - min(rs) > 0.01 * max(rs):
            add("WARN", "Узел '%s': колёса разного радиуса (%s). Один узел это один радиус: малые и большие колёса разведите по узлам." % (u.name, ", ".join("%.3f" % r for r in rs)), u)
        if abs(up.y - c) > 0.01:
            add("WARN", "Узел '%s': центр на Y=%.3f, а крайние оси посередине на Y=%.3f. Origin узла ставьте между крайними осями." % (u.name, up.y, c), u)
        if abs(up.x) > 0.02:
            add("WARN", "Узел '%s': смещён по X на %.3f, ожидается 0 (по центру колеи)." % (u.name, up.x), u)
        if rs:
            r_mean = sum(rs) / len(rs)
            if abs(up.z - (r_mean - buffer_h)) > 0.02:
                add("WARN", "Узел '%s': Z=%.3f, а по радиусу %.3f ось должна быть на Z=%.3f." % (u.name, up.z, r_mean, r_mean - buffer_h), u)
            add("INFO", unit_draft_text(u.name, unit_draft(c, ys, r_mean)), u)
    if wheels and not units:
        add("WARN", "Есть колёсные пары, но нет узлов unit_<n>: колёса должны быть детьми узлов.")

    # ---- буферы (NEM 303) ----
    # Ось буфера: у пустышки её положение, у меша центр габарита (origin меша не влияет). Если меш не симметричен
    # (рассекатель снега, подножка), центр габарита не ось буфера: тогда нужна пустышка buffer_N на оси
    bufs = [o for r, lst in roles.items() if r.startswith("buffer") for o in lst]
    if bufs:
        info = []  # (x, y, z центра, z низа, объект) в мировых осях Blender
        for o in bufs:
            a_, b_ = world_bbox(o)
            info.append(((a_[0] + b_[0]) / 2.0, (a_[1] + b_[1]) / 2.0, (a_[2] + b_[2]) / 2.0, a_[2], o))
            if o.type == "MESH":
                add("INFO", "Буфер '%s' (%s): ось по центру габарита меша, Z=%.3f (origin не учитывается)." % (o.name, role_of(o), (a_[2] + b_[2]) / 2.0), o)
                if b_[2] - a_[2] > 0.6:
                    add("WARN", "Буфер '%s': меш высотой %.2f, это не похоже на буфер (рассекатель, подножка?). Ось по центру габарита может не совпасть с осью буфера: "
                                "уберите роль и поставьте пустышку на ось (кнопка «Создать пустышки буферов»)." % (o.name, b_[2] - a_[2]), o)
            else:
                add("INFO", "Буфер '%s' (%s): пустышка, ось в её положении, Z=%.3f." % (o.name, role_of(o), (a_[2] + b_[2]) / 2.0), o)
        zs = [t[2] for t in info]
        mean_z = sum(zs) / len(zs)
        add("INFO", "Буферы (%d): ось на Z=%.3f относительно метки (NEM 303: на метке, допуск %.3f)." % (len(bufs), mean_z, BUFFER_TOL))
        if abs(mean_z) > BUFFER_TOL:
            add("ERROR", "Ось буферов на Z=%.3f, а должна быть на метке Z=0 (допуск NEM 303 ±%.3f): иначе вагон встанет буферами на другой высоте." % (mean_z, BUFFER_TOL))
        if max(zs) - min(zs) > BUFFER_TOL:
            add("WARN", "Оси буферов разной высоты (разброс %.3f)." % (max(zs) - min(zs)))
        ends = {}
        for x_, y_, z_, low_, o_ in info:
            ends.setdefault(y_ > 0, []).append(x_)
        for front, xs in ends.items():
            if len(xs) == 2:
                spacing = abs(xs[0] - xs[1])
                if abs(spacing - BUFFER_SPACING) > BUFFER_SPACING_TOL:
                    add("WARN", "Буферы %s торца: шаг осей %.3f, ожидается %.2f ±%.3f (NEM 303: 20.0 ±0.2 мм в H0, прототип 1750 мм)." %
                        ("переднего (+Y)" if front else "заднего (-Y)", spacing, BUFFER_SPACING, BUFFER_SPACING_TOL))
        for x_, y_, z_, low_, o_ in info:
            if o_.type == "MESH" and low_ + buffer_h < BUFFER_UMIN - 0.01:
                add("WARN", "Буфер '%s': нижняя кромка на %.3f над рельсом, NEM 303 требует не ниже %.3f." % (o_.name, low_ + buffer_h, BUFFER_UMIN), o_)
    else:
        add("WARN", "Нет объектов с ролью buffer_*: высоту буферов проверить нельзя. Назначьте buffer_1...buffer_4 мешам буферов или добавьте пустышки на осях "
                    "кнопкой «Создать пустышки буферов» (если буферов в модели нет, пустышка на стандартной высоте тоже годится).")

    # ---- меши: материалы, UV, треугольники ----
    tris = 0
    mats = {}
    uv2_missing = 0
    uv2_missing_names = []
    for o in meshes:
        tris += tri_count(o)
        if not o.material_slots:
            add("WARN", "Меш '%s': нет материалов." % o.name, o)
        for sl in o.material_slots:
            if sl.material is None:
                add("WARN", "Меш '%s': пустой слот материала." % o.name, o)
            else:
                mats[sl.material.name] = sl.material
        uvs = len(o.data.uv_layers)
        if uvs == 0:
            add("WARN", "Меш '%s': нет UV-карт (кнопка «Создать UV1/UV2»)." % o.name, o)
            uv2_missing_names.append(o.name)
        elif uvs < 2:
            uv2_missing += 1
            uv2_missing_names.append(o.name)
        elif uvs > 2:
            add("WARN", "Меш '%s': UV-карт %d, игра использует две (UV1 для текстур, UV2 для кисти и запекания): лишние уберите (кнопка «Убрать лишние UV»)." % (o.name, uvs), o)
    if tris > TRI_BUDGET.get(kind, 50000):
        add("WARN", "Треугольников %d, бюджет около %d." % (tris, TRI_BUDGET.get(kind, 50000)))
    add("INFO", "Мешей %d, материалов %d, треугольников %d." % (len(meshes), len(mats), tris))
    if uv2_missing_names:
        add("WARN" if brush else "INFO", "Нет второй UV-карты (UV2) у мешей: %s. Она нужна кисти Library (кнопка «Создать UV1/UV2»); без неё работает покраска по зонам." %
            ", ".join(uv2_missing_names[:8]) + (" и ещё %d" % (len(uv2_missing_names) - 8) if len(uv2_missing_names) > 8 else ""))
    paint = [n for n in mats if n.lower().startswith("paint_")]
    for name, mat in mats.items():
        if DUP_SUFFIX.search(name):
            add("WARN", "Материал '%s': хвост дубля (.001), переименуйте или слейте." % name)
        if is_transparent(mat) and not name.lower().startswith(("glass_", "emit_")):
            add("WARN", "Материал '%s' прозрачный, но имя не glass_*/emit_*." % name)
    if mats and not paint:
        add("WARN", "Нет материалов paint_*: «Весь корпус» зальёт все непрозрачные поверхности. Красимые материалы назовите paint_body, paint_roof и т. д.")
    plain = sorted(n for n in mats if not n.lower().startswith(MAT_PREFIXES))
    if paint and plain:
        add("INFO", "Материалы без префикса (красить не будут): %s." % ", ".join(plain))

    # ---- анимации ----
    seen = set()
    for o in objs:
        for act in object_actions(o):
            if act.name in seen:
                continue
            seen.add(act.name)
            if not act.name.startswith("mech_"):
                add("WARN", "Действие '%s' (объект '%s'): имя не mech_<id>. Механизмы называются mech_door_left и т. п." % (act.name, o.name), o)
            if role_of(o) is None:
                add("ERROR", "Действие '%s' двигает '%s' без роли: игра найдёт часть только по роли." % (act.name, o.name), o)
            kinds = set()
            nonlin, open_ch, cyc = 0, 0, bool(o.get("ec_cycle"))
            for fc in iter_fcurves(act):
                path = fc.data_path
                vals = [kp.co[1] for kp in fc.keyframe_points]
                moved = bool(vals) and (max(vals) - min(vals)) > 1e-4  # канал с ключами покоя без изменения не считается движением
                if path == "location" and moved:
                    kinds.add("move")
                elif path.startswith("rotation") and moved:
                    kinds.add("rot")
                elif path == "scale" and moved:
                    add("WARN", "Действие '%s': анимация масштаба не поддерживается." % act.name, o)
                if any(kp.interpolation != "LINEAR" for kp in fc.keyframe_points):
                    nonlin += 1
                if cyc and len(fc.keyframe_points) > 1 and abs(fc.keyframe_points[0].co[1] - fc.keyframe_points[-1].co[1]) > 1e-4:
                    open_ch += 1
            if nonlin:
                add("WARN", "Действие '%s': у %d каналов интерполяция не Linear (плавность даёт игра). Кнопка «Ключи → Linear» в блоке 3." % (act.name, nonlin), o)
            if open_ch:
                add("WARN", "Действие '%s': цикл не замкнут у %d каналов, последний ключ должен равняться первому. Запустите «Нормализовать привод колеса» заново." % (act.name, open_ch), o)
            if cyc:
                fr = act.frame_range
                add("INFO", "Цикл привода '%s': кадры %d..%d, %d кадров на оборот колеса (последний замыкающий)." % (act.name, fr[0], fr[1], int(round(fr[1] - fr[0]))), o)
            if kinds == {"move", "rot"} and not o.get("ec_cycle"):   # цикл привода (ec_cycle) двигает деталь и сдвигом и поворотом по замыслу
                add("WARN", "Действие '%s': и сдвиг, и поворот. Один механизм это одно движение: разделите на две детали." % act.name, o)
            declared = o.get("mech_id")
            if isinstance(declared, str) and declared and act.name != "mech_" + declared:
                add("WARN", "Объект '%s': свойство mech_id = '%s', а действие называется '%s' (ожидается mech_%s)." % (o.name, declared, act.name, declared), o)
            fr = act.frame_range
            add("INFO", "Механизм '%s' (роль %s): %s, кадры %d..%d." % (act.name, role_of(o), "/".join(sorted(kinds)) or "движения между ключами нет", fr[0], fr[1]), o)
    for act in bpy.data.actions:
        if act.name.startswith("mech_") and act.name not in seen:
            add("INFO", "Действие '%s' ни к одному объекту модели не привязано, в экспорт не попадёт." % act.name)
    return out


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


def write_text(name, text):
    t = bpy.data.texts.get(name) or bpy.data.texts.new(name)
    t.clear()
    t.write(text)


def wrap_text(text, width):
    """Перенос строки по ширине в символах (для подписей панели и окна)"""
    import textwrap
    return textwrap.wrap(text, width=max(20, int(width)), break_long_words=True, break_on_hyphens=False) or [""]


def parse_report_lines(text):
    """Строки отчёта: '[ERROR] ...' -> ('ERROR', ...); итоговая строка -> ('SUMMARY', ...)"""
    import re as _re
    out = []
    for ln in text.splitlines():
        m = _re.match(r"^\[(ERROR|WARN|INFO)\]\s*(.*)$", ln)
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
    """Делает отчёт видимым везде: панель, окно, текстовый блок и буфер обмена. Возвращает True, если скопирован в буфер"""
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
    """Подпись с переносом: первая строка с иконкой уровня, остальные с отступом"""
    icon = {"ERROR": "ERROR", "WARN": "QUESTION", "INFO": "INFO"}.get(level, "NONE")
    col = layout.column(align=True)
    col.scale_y = 0.85
    col.alert = level == "ERROR"
    for k, part in enumerate(wrap_text(text, width)):
        col.label(text=part, icon=icon if k == 0 else "BLANK1")


# ---------------------------------------------------------------- помощники

def is_animated(obj):
    """Есть ключи, NLA или драйверы: применять такому объекту трансформ нельзя (ключи вернут старые значения)"""
    ad = obj.animation_data
    return bool(object_actions(obj)) or bool(ad and ad.drivers)


def needs_apply(obj, loc):
    """Есть ли что применять: поворот, масштаб (и положение, если loc). Нулевой трансформ не трогаем: Apply сделал бы меш уникальным"""
    m = obj.matrix_basis
    if m.to_quaternion().angle > 1e-5:
        return True
    if any(abs(v - 1.0) > 1e-6 for v in m.to_scale()):
        return True
    return bool(loc and m.translation.length > 1e-6)


def prepare_transforms(scene, notes=None):
    """Кузов: Apply All Transforms. Части: только Rotation и Scale (Location не применяем: он сбросил бы origin шарнира).
    Не трогает объекты с нулевым трансформом (общие меши остаются общими) и анимированные (их нормализует «Привод колеса»);
    пропущенные попадают в notes (список строк)"""
    bodies = find_body(scene)
    if len(bodies) != 1:
        return "Нужен ровно один объект с role = body"
    notes = notes if notes is not None else []
    body = bodies[0]
    view = bpy.context.view_layer
    prev_sel = [o for o in scene.objects if o.select_get()]
    prev_act = view.objects.active
    problems = []

    def apply(obj, loc):
        if not needs_apply(obj, loc):
            return
        if is_animated(obj):
            notes.append("%s: анимирован, трансформ не применён (ключи его сбросят); соберите деталь кнопкой «Нормализовать привод колеса»" % obj.name)
            return
        for o in scene.objects:
            o.select_set(False)
        obj.select_set(True)
        view.objects.active = obj
        try:
            if obj.type == "MESH" and obj.data.users > 1:
                bpy.ops.object.make_single_user(object=True, obdata=True)
            bpy.ops.object.transform_apply(location=loc, rotation=True, scale=True)
        except RuntimeError as e:
            problems.append("%s: %s" % (obj.name, e))

    apply(body, True)
    for o in body.children_recursive:
        if o.type in {"MESH", "EMPTY"}:
            apply(o, False)
    for o in scene.objects:
        o.select_set(False)
    for o in prev_sel:
        o.select_set(True)
    view.objects.active = prev_act
    return "; ".join(problems) if problems else None


# >>> drive-cycle-math
# Чистая математика цикла привода (без bpy и mathutils; проверяется tools/test_drive_cycle.py).
# Матрица это список строк 4x4 (m[строка][столбец], перенос в последнем столбце), кватернион (w, x, y, z).

def _qmul(a, b):
    aw, ax, ay, az = a
    bw, bx, by, bz = b
    return (aw * bw - ax * bx - ay * by - az * bz,
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw)


def _qconj(q):
    return (q[0], -q[1], -q[2], -q[3])


def _qdot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]


def _qnorm(q):
    n = math.sqrt(_qdot(q, q)) or 1.0
    return (q[0] / n, q[1] / n, q[2] / n, q[3] / n)


def _vlen(v):
    return math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])


def rot_scale(m):
    """Верхняя 3x3 матрицы: M = R * diag(s), R вращение. Отражение (det < 0) уходит знаком в s[0].
    Возвращает (R, (sx, sy, sz), перекос осей: наибольший |cos| угла между колонками)"""
    cols = [(m[0][c], m[1][c], m[2][c]) for c in range(3)]
    norms = [_vlen(c) for c in cols]
    if min(norms) < 1e-12:
        raise ValueError("нулевой масштаб")
    det = (cols[0][0] * (cols[1][1] * cols[2][2] - cols[2][1] * cols[1][2])
           - cols[1][0] * (cols[0][1] * cols[2][2] - cols[2][1] * cols[0][2])
           + cols[2][0] * (cols[0][1] * cols[1][2] - cols[1][1] * cols[0][2]))
    sc = [norms[0] * (-1.0 if det < 0 else 1.0), norms[1], norms[2]]
    unit = [tuple(cols[c][r] / sc[c] for r in range(3)) for c in range(3)]
    rot = [[unit[c][r] for c in range(3)] for r in range(3)]
    skew = 0.0
    for a, b in ((0, 1), (0, 2), (1, 2)):
        d = sum(cols[a][k] * cols[b][k] for k in range(3)) / (norms[a] * norms[b])
        skew = max(skew, abs(d))
    return rot, tuple(sc), skew


def quat_from_rot(r):
    """Кватернион по матрице вращения 3x3 (строки)"""
    t = r[0][0] + r[1][1] + r[2][2]
    if t > 0:
        k = math.sqrt(t + 1.0) * 2
        q = (0.25 * k, (r[2][1] - r[1][2]) / k, (r[0][2] - r[2][0]) / k, (r[1][0] - r[0][1]) / k)
    elif r[0][0] > r[1][1] and r[0][0] > r[2][2]:
        k = math.sqrt(1.0 + r[0][0] - r[1][1] - r[2][2]) * 2
        q = ((r[2][1] - r[1][2]) / k, 0.25 * k, (r[0][1] + r[1][0]) / k, (r[0][2] + r[2][0]) / k)
    elif r[1][1] > r[2][2]:
        k = math.sqrt(1.0 + r[1][1] - r[0][0] - r[2][2]) * 2
        q = ((r[0][2] - r[2][0]) / k, (r[0][1] + r[1][0]) / k, 0.25 * k, (r[1][2] + r[2][1]) / k)
    else:
        k = math.sqrt(1.0 + r[2][2] - r[0][0] - r[1][1]) * 2
        q = ((r[1][0] - r[0][1]) / k, (r[0][2] + r[2][0]) / k, (r[1][2] + r[2][1]) / k, 0.25 * k)
    return _qnorm(q)


def track_from_worlds(worlds):
    """worlds: матрицы 4x4 детали (относительно кузова) по кадрам цикла, кадр 0 это покой.
    Возвращает словарь: u (3x3 R0*S0: в неё переводятся вершины меша, тогда узел стоит без поворота и масштаба),
    loc (положение узла по кадрам), quat (поворот относительно покоя по кадрам, знак непрерывный),
    scale_dev (на сколько менялся масштаб по осям), skew (наибольший перекос осей)"""
    rot0, s0, skew = rot_scale(worlds[0])
    q0c = _qconj(quat_from_rot(rot0))
    u = [[worlds[0][r][c] for c in range(3)] for r in range(3)]
    loc, quat = [], []
    prev = (1.0, 0.0, 0.0, 0.0)
    sdev = 0.0
    for w in worlds:
        rot, sc, sk = rot_scale(w)
        q = _qnorm(_qmul(quat_from_rot(rot), q0c))
        if _qdot(q, prev) < 0:
            q = (-q[0], -q[1], -q[2], -q[3])
        prev = q
        quat.append(q)
        loc.append((w[0][3], w[1][3], w[2][3]))
        sdev = max(sdev, abs(sc[0] - s0[0]), abs(sc[1] - s0[1]), abs(sc[2] - s0[2]))
        skew = max(skew, sk)
    return {"u": u, "loc": loc, "quat": quat, "scale_dev": sdev, "skew": skew}


def wheel_step(w0, w1):
    """Поворот колеса между двумя соседними кадрами в мировых осях: (градусы вокруг +X со знаком, |ось X|).
    Нос модели +Y: качение вперёд это отрицательный поворот вокруг +X"""
    d = _qmul(quat_from_rot(rot_scale(w1)[0]), _qconj(quat_from_rot(rot_scale(w0)[0])))
    if d[0] < 0:
        d = (-d[0], -d[1], -d[2], -d[3])
    vl = _vlen(d[1:])
    if vl < 1e-12:
        return 0.0, 0.0
    ax = d[1] / vl
    return math.degrees(2 * math.atan2(vl, d[0])) * ax, abs(ax)


def cycle_period(step_deg, tol=0.05):
    """Кадров на оборот по шагу колеса (градусы за кадр); None, если оборот не укладывается в целое число кадров"""
    if abs(step_deg) < 1e-6:
        return None
    n = 360.0 / abs(step_deg)
    p = int(round(n))
    return p if p >= 2 and abs(n - p) <= tol else None


def cycle_order(n_src, period, reverse):
    """Номера исходных кадров для кадров цикла 0..period (последний замыкающий, равен нулевому).
    reverse: исходная анимация крутит колесо назад, порядок разворачивается, чтобы рост кадра шёл вперёд по ходу.
    None, если исходных кадров меньше оборота"""
    if period < 2 or n_src < period:
        return None
    return [((-k) % period) if reverse else (k % period) for k in range(period + 1)]


def drive_role(name, prefix="drv_"):
    """Роль детали привода из имени объекта: drv_<имя>, без хвоста дубля и лишних знаков"""
    base = re.sub(r"[.]\d{3,}$", "", name).lower()
    base = re.sub(r"[^a-z0-9_]+", "_", base).strip("_")
    return prefix + (base or "part")
# <<< drive-cycle-math

# >>> unit-math
# Узлы тележек (чистая математика, без bpy; проверяется tools/test_drive_cycle.py).
UNIT_RE = re.compile(r"^unit_(\d+)$")
WHEEL_ROLE_RE = re.compile(r"^wheel_(\d+)_(\d+)$")
FLANGE_DEPTH = 0.05   # реборда колеса уходит ниже головки рельса (единицы = метры прототипа)


def next_unit_number(roles):
    used = [int(m.group(1)) for m in (UNIT_RE.match(r) for r in roles) if m]
    return max(used) + 1 if used else 1


def unit_layout(ys):
    """ys: положения осей вдоль Y (нос +Y). Возвращает (центр между крайними осями, смещения осей от центра по возрастанию Y, перекос)"""
    v = sorted(ys)
    c = (v[0] + v[-1]) / 2.0
    offs = [y - c for y in v]
    return c, offs, abs(offs[0] + offs[-1])


def axle_radius(axle_z, buffer_h):
    """Радиус круга катания: ось над головкой рельса (рельс на Z = -buffer_h при метке Z=0 на оси буферов)"""
    return axle_z + buffer_h


def unit_draft(center_y, wheel_ys, radius):
    """Числа для BogieConfig в осях Godot (Z Godot = -Y Blender): b_offset_z, радиус, оси по Z относительно узла по возрастанию"""
    return {"b_offset_z": -center_y, "radius": radius, "axles": sorted(-(y - center_y) for y in wheel_ys)}


def unit_draft_text(name, d):
    ax = ", ".join("%.3f" % z for z in d["axles"])
    txt = "Заготовка BogieConfig из узла '%s': b_offset_z = %.3f, радиус колеса = %.3f, оси по Z относительно узла (Godot) = [%s]." % (name, d["b_offset_z"], d["radius"], ax)
    if len(d["axles"]) <= 2 and abs(d["axles"][0] + d["axles"][-1]) < 0.01:
        txt += " Для 1 или 2 симметричных осей: wheel_pair_position = Vector3(0, %.3f, %.3f)." % (d["radius"], abs(d["axles"][-1]))
    else:
        txt += " Больше двух осей или несимметрично: нужен BogieConfig с axle_offsets (этап K2)."
    return txt
# <<< unit-math


def _rows(m):
    return [[float(m[r][c]) for c in range(4)] for r in range(4)]


def _sample_worlds(scene, objs, frames, body_inv):
    """Матрицы объектов относительно кузова на заданных кадрах (с учётом всех родителей и анимации)"""
    out = {o.name: [] for o in objs}
    for f in frames:
        scene.frame_set(f)
        dg = bpy.context.evaluated_depsgraph_get()
        for o in objs:
            out[o.name].append(_rows(body_inv @ o.evaluated_get(dg).matrix_world))
    return out


MODEL_COLLECTION = "MODEL"


def _geometry_of(part):
    """Меши, которые едут вместе с деталью: она сама (если меш) и потомки без собственной анимации
    (потомок с анимацией со своим поддеревом это отдельная деталь привода)"""
    out = [part] if part.type == "MESH" else []

    def walk(o):
        for c in o.children:
            if is_animated(c):
                continue
            if c.type == "MESH":
                out.append(c)
            walk(c)
    walk(part)
    return out


def _label(obj):
    """Имя для копии: у меша от импорта (имя_DD17_0 внутри пустышки) берём имя пустышки-родителя, если меш в ней один"""
    p = obj.parent
    if p is not None and p.type == "EMPTY" and sum(1 for c in p.children if c.type == "MESH") == 1:
        return p.name
    return obj.name


def _model_collection(scene):
    c = bpy.data.collections.get(MODEL_COLLECTION)
    if c is None:
        c = bpy.data.collections.new(MODEL_COLLECTION)
    if not c.users:
        scene.collection.children.link(c)
    return c


def _join(context, objs):
    """Склеивает объекты в первый (его имя и origin остаются); меши и материалы объединяются"""
    if len(objs) == 1:
        return objs[0]
    with context.temp_override(active_object=objs[0], selected_editable_objects=list(objs), selected_objects=list(objs)):
        bpy.ops.object.join()
    return objs[0]


def _adopt(obj, parent):
    """Делает obj потомком parent с сохранением мирового положения, без смещения родителя в matrix_parent_inverse"""
    bpy.context.view_layer.update()
    mw = obj.matrix_world.copy()
    obj.parent = parent
    obj.matrix_parent_inverse = Matrix.Identity(4)
    obj.matrix_world = mw


def _world_mesh(src, world, shift=(0.0, 0.0, 0.0)):
    """Копия данных меша, переведённая матрицей world (4x4, строки), с вычитанием сдвига из переноса"""
    rows = [list(world[r][:3]) + [world[r][3] - shift[r]] for r in range(3)] + [[0.0, 0.0, 0.0, 1.0]]
    m = Matrix(rows)
    mesh = src.data.copy()
    mesh.transform(m)
    if m.determinant() < 0:
        mesh.flip_normals()
    return mesh


def bake_drive_cycle(context, body, wheel, parts, cycle_id):
    """Привод колеса: детали пересобираются чистыми детьми кузова (в покое без поворота и масштаба), движение запекается
    в замкнутый цикл на один оборот эталонного колеса, одним действием mech_<cycle_id> (по слоту на деталь).
    Деталь это анимированный объект: меш или пустышка-шарнир с мешами внутри (меши детали склеиваются в один, origin в шарнире).
    Оборот берётся по самому колесу: n = 360 / шаг за кадр. Рост кадра = движение вперёд (нос +Y); если исходная анимация
    крутит назад, порядок кадров разворачивается. Исходные объекты не меняются. Возвращает (ошибка или None, строки отчёта)"""
    scene = context.scene
    items = []

    def info(lv, tx):
        items.append((lv, tx, None))

    if "slots" not in bpy.types.Action.bl_rna.properties:
        return "Нужен Blender 4.4 или новее: одно действие на несколько объектов (слоты действия)", items
    if not re.match(r"^[a-z][a-z0-9_]*$", cycle_id or ""):
        return "Id цикла: a-z, 0-9, _, начинается с буквы", items
    if wheel is None or wheel == body or not is_animated(wheel):
        return "Активным должно быть колесо с анимацией оборота (остальное выделение это детали привода)", items
    sel = [o for o in parts if o != wheel and o != body]
    parts = [o for o in sel if is_animated(o)]
    if not parts:
        return "Выделите детали привода (шатуны, дышла, парораспределение), активным сделайте колесо", items
    bad = [o.name for o in parts if o.type not in {"MESH", "EMPTY"}]
    if bad:
        return "Деталь привода это меш или пустышка с мешами: %s" % ", ".join(bad), items
    geos = {o.name: _geometry_of(o) for o in parts}
    empty = [n for n, g in geos.items() if not g]
    if empty:
        return "Нет мешей внутри: %s" % ", ".join(empty), items
    covered = {g.name for lst in geos.values() for g in lst}
    stray = [o.name for o in sel if not is_animated(o) and o.name not in covered]
    if stray:
        info("WARN", "Выделено, но не входит ни в одну деталь привода (пропущено): %s" % ", ".join(stray))
    shared = {}
    for n, lst in geos.items():
        for g in lst:
            shared.setdefault(g.name, []).append(n)
    twice = [g for g, ns in shared.items() if len(ns) > 1]
    if twice:
        return "Меш входит в две детали: %s" % ", ".join(twice), items

    rng = [a.frame_range for o in [wheel] + parts for a in object_actions(o)]
    f0 = int(math.floor(min(r[0] for r in rng) + 1e-6))
    f1 = int(math.ceil(max(r[1] for r in rng) - 1e-6))
    n_src = f1 - f0 + 1
    all_geo = [g for lst in geos.values() for g in lst]
    saved = scene.frame_current
    try:
        scene.frame_set(f0)
        body_inv = body.matrix_world.inverted()
        ref = _sample_worlds(scene, [wheel], [f0, f0 + 1], body_inv)[wheel.name]
        step, axis_x = wheel_step(ref[0], ref[1])
        if axis_x < 0.9:
            return ("Колесо '%s' вращается не вокруг оси X (|ось X| = %.2f). Нос модели должен смотреть в +Y, колёсные пары лежать "
                    "осью вдоль X: проверьте ориентацию корня исходной модели" % (wheel.name, axis_x)), items
        period = cycle_period(step)
        if period is None:
            return "Колесо '%s' поворачивается на %.3f° за кадр: оборот не укладывается в целое число кадров" % (wheel.name, step), items
        order = cycle_order(n_src, period, step > 0)
        if order is None:
            return "Анимация короче оборота: %d кадров, нужно %d (колесо '%s', %.3f° за кадр)" % (n_src, period, wheel.name, step), items
        if n_src != period:
            info("WARN", "В анимации %d кадров, оборот колеса %d: лишние кадры отброшены" % (n_src, period))
        worlds = _sample_worlds(scene, parts, [f0 + i for i in range(period)], body_inv)
        geo_w = _sample_worlds(scene, all_geo, [f0], body_inv)
        tracks = []
        for o in parts:
            tr = track_from_worlds([worlds[o.name][i] for i in order])
            if tr["scale_dev"] > 1e-3:
                info("WARN", "%s: масштаб меняется в анимации (на %.3f), в цикл он не переносится" % (o.name, tr["scale_dev"]))
            if tr["skew"] > 1e-3:
                info("WARN", "%s: оси перекошены (родитель с неравномерным масштабом): форма в покое может отличаться" % o.name)
            for g in geos[o.name]:
                if g.modifiers:
                    info("WARN", "%s: модификаторы не переносятся (берутся данные меша)" % g.name)
            tracks.append(tr)
    except ValueError as e:
        return "Нулевой масштаб у детали: %s" % e, items
    finally:
        scene.frame_set(saved)

    roles, seen = [], set()
    for o in parts:
        r = drive_role(o.name)
        k = 2
        while r in seen:
            r = "%s_%d" % (drive_role(o.name), k)
            k += 1
        seen.add(r)
        roles.append(r)

    # повторный запуск: прежний результат этого цикла заменяется
    for o in list(bpy.data.objects):
        if o.get("ec_cycle") == cycle_id:
            bpy.data.objects.remove(o, do_unlink=True)
    act_name = "mech_" + cycle_id
    old = bpy.data.actions.get(act_name)
    if old is not None and old.users == 0:
        bpy.data.actions.remove(old)
    for r in roles:
        if bpy.data.objects.get(r) is not None:
            return "Объект '%s' уже есть в файле (не от этого инструмента): переименуйте или удалите" % r, items

    coll = body.users_collection[0] if body.users_collection else scene.collection
    act = bpy.data.actions.new(act_name)
    edit = bpy.context.preferences.edit
    prev_interp = edit.keyframe_new_interpolation_type
    edit.keyframe_new_interpolation_type = "LINEAR"
    try:
        for o, r, tr in zip(parts, roles, tracks):
            t0 = tr["loc"][0]
            made = []
            for k, g in enumerate(geos[o.name]):
                ob = bpy.data.objects.new("%s_%d" % (r, k), _world_mesh(g, geo_w[g.name][0], t0))
                coll.objects.link(ob)
                made.append(ob)
            new = _join(context, made)
            new.name = r
            new.data.name = r
            new.parent = body
            new["role"] = r
            new["ec_cycle"] = cycle_id
            new["mech_id"] = cycle_id
            new.rotation_mode = "QUATERNION"
            ad = new.animation_data_create()
            slot = act.slots.new(id_type="OBJECT", name=new.name)
            ad.action = act
            ad.action_slot = slot
            for k in range(period + 1):
                new.location = tr["loc"][k]
                new.rotation_quaternion = tr["quat"][k]
                new.keyframe_insert("location", frame=f0 + k)
                new.keyframe_insert("rotation_quaternion", frame=f0 + k)
            new.location = t0
            new.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
    finally:
        edit.keyframe_new_interpolation_type = prev_interp
    set_linear(act)   # настройка по умолчанию на keyframe_insert не всегда действует (в Blender 5 нет): ставим явно
    if scene.frame_end < f0 + period:
        scene.frame_end = f0 + period
    scene.frame_set(saved)
    info("INFO", "Колесо '%s': %.3f° за кадр, оборот %d кадров; кадры цикла %d..%d, последний замыкающий" % (wheel.name, step, period, f0, f0 + period))
    info("INFO", "Рост кадра = движение вперёд%s" % (" (исходный порядок кадров развёрнут)" if step > 0 else ""))
    info("INFO", "Создано деталей: %d, действие '%s': %s" % (len(parts), act_name, ", ".join(roles)))
    info("INFO", "Origin детали в точке её шарнира (у пустышки это её положение): проверьте на кадре 0 и 24")
    info("INFO", "Обе стороны одной детали движутся синфазно: если на колёсной паре пальцы кривошипа сдвинуты на 90°, "
         "делите деталь на левую и правую до запекания")
    return None, items


def static_copies(context, meshes, to_center):
    """Чистые копии мешей в позе текущего кадра: данные в мировых координатах, трансформ нулевой, без родителей и анимации.
    to_center: origin в центр габарита (для колёсных пар: центр оси). Возвращает объекты в коллекции MODEL"""
    scene = context.scene
    coll = _model_collection(scene)
    dg = bpy.context.evaluated_depsgraph_get()
    out = []
    for src in meshes:
        world = _rows(src.evaluated_get(dg).matrix_world)
        name = drive_role(_label(src), prefix="")
        other = bpy.data.objects.get(name)
        if other is not None and other.get("ec_copy") is None:
            other.name = name + "_src"      # имя нужно копии: id зоны покраски строится из имени узла
        ob = bpy.data.objects.new(name, _world_mesh(src, world))
        coll.objects.link(ob)
        ob.data.name = ob.name
        if to_center and ob.data.vertices:
            cs = [v.co for v in ob.data.vertices]
            c = Vector([(min(p[i] for p in cs) + max(p[i] for p in cs)) / 2 for i in range(3)])
            ob.data.transform(Matrix.Translation(-c))
            ob.location = c
        ob["ec_copy"] = "copy"
        out.append(ob)
    return out


def _box(verts, faces, cx, cy, cz, sx, sy, sz):
    k = len(verts)
    for dx in (-0.5, 0.5):
        for dy in (-0.5, 0.5):
            for dz in (-0.5, 0.5):
                verts.append((cx + dx * sx, cy + dy * sy, cz + dz * sz))
    for f in ((0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)):
        faces.append(tuple(k + i for i in f))


def _cylinder_x(verts, faces, x0, x1, cy, cz, radius, n=32):
    """Цилиндр с осью вдоль X: кольца на x0 и x1, центр (cy, cz) в осях Y, Z"""
    k = len(verts)
    for x in (x0, x1):
        for i in range(n):
            a = 2 * math.pi * i / n
            verts.append((x, cy + radius * math.cos(a), cz + radius * math.sin(a)))
    for i in range(n):
        j = (i + 1) % n
        faces.append((k + i, k + j, k + n + j, k + n + i))
    faces.append(tuple(k + i for i in range(n - 1, -1, -1)))
    faces.append(tuple(k + n + i for i in range(n)))


def make_refs(scene, buffer_h, wheel_d, ys, gauge=GAUGE):
    """Эталон (коллекция EC_ref, в экспорт не входит): два рельса-бокса 0.1 x 25 x 0.25 с внутренними гранями на расстоянии gauge,
    верх рельса на Z = -buffer_h; колёсные пары (два колеса и ось) диаметром wheel_d, колёса в центрах колеи (x = ±gauge/2),
    низ колеса на головке рельса. Возвращает (число рельсов, число колёсных пар)"""
    col = bpy.data.collections.get(REF_COLLECTION) or bpy.data.collections.new(REF_COLLECTION)
    if col.name not in scene.collection.children:
        scene.collection.children.link(col)
    for o in list(col.objects):
        bpy.data.objects.remove(o, do_unlink=True)

    def new_obj(name, verts, faces):
        me = bpy.data.meshes.new(name + "_mesh")
        me.from_pydata(verts, [], faces)
        me.update()
        ob = bpy.data.objects.new(name, me)
        ob.display_type = "WIRE"
        ob.hide_render = True
        col.objects.link(ob)
        return ob

    for name, side in (("EC_ref_rail_L", -1), ("EC_ref_rail_R", 1)):
        v, f = [], []
        _box(v, f, side * (gauge / 2.0 + RAIL_W / 2.0), 0.0, -buffer_h - RAIL_H / 2.0, RAIL_W, RAIL_LEN, RAIL_H)
        new_obj(name, v, f)
    r = wheel_d / 2.0
    for k, y in enumerate(ys):
        v, f = [], []
        cz = r - buffer_h
        for side in (-1, 1):
            _cylinder_x(v, f, side * gauge / 2.0 - WHEEL_T / 2.0, side * gauge / 2.0 + WHEEL_T / 2.0, y, cz, r)
        _cylinder_x(v, f, -gauge / 2.0, gauge / 2.0, y, cz, min(AXLE_R, r * 0.5), 16)
        new_obj("EC_ref_wheelset_%d" % k, v, f)
    return 2, len(ys)


def add_buffer_empties(scene):
    """Пустышки buffer_1...buffer_4 на осях буферов (Z=0, шаг BUFFER_SPACING, торцы кузова по Y), детьми кузова. Существующие роли не дублирует.
    Возвращает (созданные имена, текст ошибки или None)"""
    bodies = find_body(scene)
    if len(bodies) != 1:
        return [], "Нужен ровно один объект с role = body"
    body = bodies[0]
    have = {role_of(o) for o in export_set(body)}
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in export_set(body):
        if o.type == "MESH":
            a, b = world_bbox(o)
            for i in range(3):
                lo[i] = min(lo[i], a[i])
                hi[i] = max(hi[i], b[i])
    if lo[1] > hi[1]:
        return [], "В модели нет мешей"
    x = BUFFER_SPACING / 2.0
    spec = (("buffer_1", x, hi[1]), ("buffer_2", -x, hi[1]), ("buffer_3", x, lo[1]), ("buffer_4", -x, lo[1]))
    made = []
    for role, bx, by in spec:
        if role in have:
            continue
        e = bpy.data.objects.new("Buffer_" + role[-1], None)
        e.empty_display_type = "SPHERE"
        e.empty_display_size = 0.15
        scene.collection.objects.link(e)
        e.parent = body
        e.matrix_parent_inverse = body.matrix_world.inverted()
        e.location = (bx, by, 0.0)
        e["role"] = role
        made.append(e.name)
    return made, None


def mesh_datas(scene):
    """Меши модели без повторов по данным (общие данные обрабатываются один раз): [(объект, данные)]"""
    bodies = find_body(scene)
    if len(bodies) != 1:
        return []
    out, seen = [], set()
    for o in export_set(bodies[0]):
        if o.type == "MESH" and o.data not in seen:
            seen.add(o.data)
            out.append((o, o.data))
    return out


def ensure_uvs(scene):
    """Каждому мешу модели доводит число UV-карт до двух: UV1 (Smart UV Project, если карт нет) и UV2 (Lightmap Pack: без перекрытий).
    Существующие карты не трогает. Возвращает (список 'меш: что создано', список ошибок)"""
    view = bpy.context.view_layer
    prev_sel = [o for o in scene.objects if o.select_get()]
    prev_act = view.objects.active
    made, problems = [], []

    def unwrap(o, layer, how):
        for x in scene.objects:
            x.select_set(False)
        o.select_set(True)
        view.objects.active = o
        o.data.uv_layers.active = layer
        bpy.ops.object.mode_set(mode="EDIT")
        try:
            bpy.ops.mesh.select_all(action="SELECT")
            if how == "smart":
                bpy.ops.uv.smart_project(**export_params(bpy.ops.uv.smart_project, angle_limit=math.radians(66.0), island_margin=0.02))
            else:
                # набор параметров lightmap_pack меняется между версиями Blender: передаём только существующие
                bpy.ops.uv.lightmap_pack(**export_params(bpy.ops.uv.lightmap_pack, PREF_CONTEXT="ALL_FACES", PREF_PACK_IN_ONE=True,
                                                         PREF_NEW_UVLAYER=False, PREF_APPLY_IMAGE=False, PREF_IMG_PX_SIZE=1024,
                                                         PREF_BOX_DIV=12, PREF_MARGIN_DIV=0.1))
        finally:
            bpy.ops.object.mode_set(mode="OBJECT")

    try:
        if view.objects.active is not None and view.objects.active.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
        for o, me in mesh_datas(scene):
            n = len(me.uv_layers)
            if n >= 2:
                continue
            did = []
            created = []
            try:
                if n == 0:
                    first = me.uv_layers.new(name="UV1")
                    created.append(first.name)
                    unwrap(o, first, "smart")
                    did.append("UV1")
                second = me.uv_layers.new(name="UV2")
                created.append(second.name)
                unwrap(o, second, "lightmap")
                did.append("UV2")
                me.uv_layers.active_index = 0
                me.uv_layers[0].active_render = True
                made.append("%s: %s" % (o.name, ", ".join(did)))
            except (RuntimeError, TypeError) as e:
                # откат: недоделанные карты не оставляем (пустая вторая карта хуже, чем её отсутствие)
                for nm in created:
                    lay = me.uv_layers.get(nm)
                    if lay is not None:
                        me.uv_layers.remove(lay)
                problems.append("%s: %s" % (o.name, e))
    finally:
        for x in scene.objects:
            x.select_set(False)
        for o in prev_sel:
            try:
                o.select_set(True)
            except RuntimeError:
                pass
        view.objects.active = prev_act
    return made, problems


def pack_shared_uv2(scene, margin=0.01):
    """UV2 всех мешей модели в один общий лист: острова всех мешей получают одну плотность (Average Islands Scale)
    и упаковываются вместе без перекрытий. Нужна для кисти Library: один слой краски на всю модель.
    Работает со второй UV-картой (UV2) каждого меша; у кого её нет, сначала «Создать UV1/UV2».
    Возвращает (сколько мешей упаковано, список проблем)"""
    view = bpy.context.view_layer
    tool = scene.tool_settings
    pairs = mesh_datas(scene)
    problems = []
    objs = []
    for o, me in pairs:
        if len(me.uv_layers) < 2:
            problems.append("%s: нет второй UV-карты (сначала «Создать UV1/UV2»)" % o.name)
        else:
            objs.append((o, me))
    if problems or not objs:
        return 0, problems or ["в модели нет мешей"]
    prev_sel = [o for o in scene.objects if o.select_get()]
    prev_act = view.objects.active
    prev_sync = tool.use_uv_select_sync
    prev_active_uv = {me.name: me.uv_layers.active_index for _o, me in objs}
    try:
        if prev_act is not None and prev_act.mode != "OBJECT":
            bpy.ops.object.mode_set(mode="OBJECT")
        for x in scene.objects:
            x.select_set(False)
        for o, me in objs:
            o.select_set(True)
            me.uv_layers.active_index = 1     # правим вторую карту
        view.objects.active = objs[0][0]
        tool.use_uv_select_sync = True        # выбор UV следует за выбором граней: все UV выбраны без окна UV-редактора
        bpy.ops.object.mode_set(mode="EDIT")  # правка сразу всех выбранных мешей (Multi-Object Editing)
        try:
            bpy.ops.mesh.select_all(action="SELECT")
            bpy.ops.uv.average_islands_scale()
            bpy.ops.uv.pack_islands(**export_params(bpy.ops.uv.pack_islands, rotate=True, margin=margin))
        finally:
            bpy.ops.object.mode_set(mode="OBJECT")
    except (RuntimeError, TypeError) as e:
        problems.append(str(e))
    finally:
        tool.use_uv_select_sync = prev_sync
        for _o, me in objs:
            me.uv_layers.active_index = prev_active_uv.get(me.name, 0)
        for x in scene.objects:
            x.select_set(False)
        for o in prev_sel:
            try:
                o.select_set(True)
            except RuntimeError:
                pass
        view.objects.active = prev_act
    return (0 if problems else len(objs)), problems


def trim_uvs(scene, keep=2):
    """Оставляет у мешей модели первые keep UV-карт. Возвращает список 'меш: сколько убрано'"""
    out = []
    for o, me in mesh_datas(scene):
        n = len(me.uv_layers)
        if n <= keep:
            continue
        while len(me.uv_layers) > keep:
            me.uv_layers.remove(me.uv_layers[len(me.uv_layers) - 1])
        me.uv_layers.active_index = 0
        out.append("%s: убрано %d" % (o.name, n - keep))
    return out


def rotation_path(obj):
    return {"QUATERNION": "rotation_quaternion", "AXIS_ANGLE": "rotation_axis_angle"}.get(obj.rotation_mode, "rotation_euler")


def set_linear(act):
    for fc in iter_fcurves(act):
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"


def remove_static_channels(act, eps=1e-4):
    """Удаляет из действия каналы, у которых все ключи равны (ключи покоя без движения): в .glb остаётся только то, что двигается.
    Возвращает число удалённых каналов"""
    static = []
    for fc in iter_fcurves(act):
        vals = [kp.co[1] for kp in fc.keyframe_points]
        if vals and (max(vals) - min(vals)) <= eps:
            static.append(fc)
    removed = 0
    for fc in static:
        container = getattr(act, "fcurves", None)
        try:
            if container is not None:
                container.remove(fc)
            else:
                for layer in act.layers:
                    for strip in layer.strips:
                        for cb in getattr(strip, "channelbags", []):
                            if fc in list(cb.fcurves):
                                cb.fcurves.remove(fc)
            removed += 1
        except (RuntimeError, ReferenceError, TypeError):
            pass
    return removed


def object_mech_id(obj):
    """Id механизма объекта: из имени его действия mech_<id>, иначе из Custom Property mech_id (её пишет «Ключ: покой»). None, если нет"""
    if obj is None:
        return None
    for act in object_actions(obj):
        if act.name.startswith("mech_"):
            return act.name[5:]
    v = obj.get("mech_id")
    return v if isinstance(v, str) and v else None


def mech_id_taken(scene, obj, mech_id):
    """Имя объекта, у которого уже есть действие mech_<mech_id> (кроме obj), иначе None: Blender дописал бы к имени .001"""
    name = "mech_" + mech_id
    for o in scene.objects:
        if o is not obj and any(a.name == name for a in object_actions(o)):
            return o.name
    return None


def mech_key(scene, obj, mech_id, frame, rest):
    obj.keyframe_insert(data_path="location", frame=frame)
    obj.keyframe_insert(data_path=rotation_path(obj), frame=frame)
    act = obj.animation_data.action if obj.animation_data else None
    if act is None:
        return None
    if rest:
        act.name = "mech_" + mech_id
        obj["mech_id"] = mech_id  # видно во вкладке Object, Custom Properties; уйдёт в extras узла
    else:
        remove_static_channels(act)  # после ключа рабочего положения лишние каналы без движения не нужны
    set_linear(act)
    return act


# Id механизма в панели следует за активным объектом (msgbus: смена активного объекта)
_MSGBUS_OWNER = object()


def _on_active_changed():
    try:
        mid = object_mech_id(bpy.context.view_layer.objects.active)
        if mid:
            bpy.context.scene.ec_tools.mech_id = mid
    except Exception:
        pass


def subscribe_active_object():
    try:
        bpy.msgbus.clear_by_owner(_MSGBUS_OWNER)
        bpy.msgbus.subscribe_rna(key=(bpy.types.LayerObjects, "active"), owner=_MSGBUS_OWNER, args=(), notify=_on_active_changed)
    except Exception:
        pass


@bpy.app.handlers.persistent
def _load_post(_dummy=None):
    subscribe_active_object()


def export_params(op, **wanted):
    """Оставляет только те параметры, которые есть у оператора в этой версии Blender"""
    names = {p.identifier for p in op.get_rna_type().properties}
    return {k: v for k, v in wanted.items() if k in names}


def do_export(scene, filepath, kind="trains", buffer_h=BUFFER_H, brush=False, run_preflight=True):
    """Экспорт кузова с потомками. Возвращает (ok, сообщение, отчёт: проверка модели и проверка готового файла)"""
    items = check_model(scene, buffer_h, kind, brush)
    if any(lv == "ERROR" for lv, _, _ in items):
        return False, "Экспорт остановлен: в проверке есть ERROR.", format_report(items)
    body = find_body(scene)[0]
    view = bpy.context.view_layer
    prev_sel = [o for o in scene.objects if o.select_get()]
    prev_act = view.objects.active
    for o in scene.objects:
        o.select_set(False)
    for o in export_set(body):
        try:
            o.select_set(True)
        except RuntimeError:
            pass
    view.objects.active = body
    os.makedirs(os.path.dirname(filepath) or ".", exist_ok=True)
    kw = export_params(
        bpy.ops.export_scene.gltf,
        filepath=filepath, export_format="GLB", use_selection=True, export_apply=True, export_extras=True,
        export_cameras=False, export_lights=False, export_yup=True, export_animations=True,
        export_animation_mode="ACTIONS", export_force_sampling=False, export_skins=False, export_morph=False,
        export_draco_mesh_compression_enable=False, export_texcoords=True, export_normals=True, export_materials="EXPORT",
        export_image_format="AUTO", export_attributes=False,
    )
    try:
        bpy.ops.export_scene.gltf(**kw)
    finally:
        for o in scene.objects:
            o.select_set(False)
        for o in prev_sel:
            try:
                o.select_set(True)
            except RuntimeError:
                pass
        view.objects.active = prev_act
    report = ""
    pre = run_preflight_tool(filepath, kind, brush) if run_preflight else ""
    report = format_report(items)
    if pre:
        report += "\n\n=== Проверка готового файла (glb_preflight) ===\n" + pre
    return True, "Экспортировано: %s" % filepath, report


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


def run_preflight_tool(glb, kind, brush):
    pf = preflight_path()
    if pf is None:
        return "tools/glb_preflight.py не найден: запустите проверку файла вручную."
    cmd = [sys.executable, str(pf), glb, "--kind", "building" if kind == "buildings" else "wagon"]
    if brush:
        cmd.append("--brush")
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", timeout=120)
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


def model_id_of(s):
    """Id модели: из панели, иначе имя файла .blend"""
    mid = (getattr(s, "model_id", "") or "").strip()
    if mid:
        return mid
    return Path(bpy.data.filepath).stem if bpy.data.filepath else "model"


def default_export_path(s):
    mid = model_id_of(s)
    return str(models_dir_of(s) / mid / (mid + ".glb"))


# ---------------------------------------------------------------- Blender: свойства, операторы, панель

class ECSettings(bpy.types.PropertyGroup):
    kind: EnumProperty(name="Вид", items=[("trains", "Подвижной состав", ""), ("buildings", "Здание", "")], default="trains")
    model_id: StringProperty(name="Id модели", description="Имя файла и папки: wagon_04. Пусто: имя файла .blend", default="")
    models_dir: StringProperty(name="Папка моделей", description="Куда экспортировать: <папка>/<id>/<id>.glb (каталог data/models репозитория)",
                               subtype="DIR_PATH", default=DEFAULT_MODELS_DIR)
    gauge: FloatProperty(name="Колея", description="Расстояние между внутренними гранями рельсов, единицы игры", default=GAUGE, min=0.5, max=4.0, precision=3)
    buffer_h: FloatProperty(name="Высота буферов", description="Ось буферов над головкой рельса, единицы игры (1 = 1 м прототипа), NEM 303: 12.2 мм в H0 = 1.061",
                            default=BUFFER_H, min=0.5, max=2.0, precision=3)
    wheel_d: FloatProperty(name="Диаметр колеса", description="Для эталонных колёсных пар", default=1.0, min=0.3, max=3.0, precision=3)
    wheel_ys: StringProperty(name="Колёсные пары по Y", description="Положения колёсных пар вдоль вагона через запятую (+Y нос)", default="-5, -3.5, 3.5, 5")
    role: StringProperty(name="Роль", description="Custom Property role для выделенных объектов", default="")
    role_preset: EnumProperty(name="Шаблон", items=ROLE_PRESETS, default="body")
    mech_id: StringProperty(name="Id механизма", description="Имя действия станет mech_<id>", default="door_left")
    unit_frame: BoolProperty(name="Активный это рама узла", description="При создании узла активный объект становится рамой узла (role frame_<n>), остальные выделенные колёсными парами", default=False)
    copy_center: BoolProperty(name="Origin в центр габарита", description="Для копий колёсных пар: origin в центр оси (центр габарита)", default=True)
    cycle_id: StringProperty(name="Id цикла", description="Действие цикла привода станет mech_<id>", default="drive")
    mech_frames: IntProperty(name="Кадров хода", description="Длина хода механизма в кадрах (24 кадра = 1 с при 24 к/с)", default=24, min=2, max=600)
    wrap: IntProperty(name="Перенос строк", description="Ширина строки отчёта в панели, символов (подберите под ширину панели)", default=46, min=24, max=200)
    show_info: BoolProperty(name="Показывать INFO", description="В панели показывать и справочные строки (габариты, заготовки конфигов); в окне и буфере обмена они есть всегда", default=False)
    brush: BoolProperty(name="Нужна кисть (UV2)", description="Отсутствие второй UV-карты считать предупреждением", default=False)
    export_path: StringProperty(name="Файл .glb", description="Пусто: <Папка моделей>/<id>/<id>.glb", subtype="FILE_PATH", default="")


class EC_OT_check(bpy.types.Operator):
    bl_idname = "ec.check"
    bl_label = "Проверить модель"
    bl_description = "Проверка по правилам 0_ATTN_24. Отчёт появляется в панели, копируется в буфер обмена и пишется в текст EC_report"

    def execute(self, context):
        s = settings(context.scene)
        items = check_model(context.scene, s.buffer_h, s.kind, s.brush)
        text = format_report(items)
        copied = publish_report("Проверка модели", text, REPORT_TEXT)
        e, w, i = summarize(items)
        self.report({"ERROR"} if e else ({"WARNING"} if w else {"INFO"}),
                    "ERROR %d, WARN %d, INFO %d. %s" % (e, w, i, "Отчёт скопирован в буфер обмена" if copied else "Отчёт в тексте EC_report"))
        print(text)
        return {"FINISHED"}


class EC_OT_show_report(bpy.types.Operator):
    bl_idname = "ec.show_report"
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


class EC_OT_copy_report(bpy.types.Operator):
    bl_idname = "ec.copy_report"
    bl_label = "Копировать отчёт"
    bl_description = "Копирует весь последний отчёт в буфер обмена (потом Ctrl+V в чат или файл)"

    def execute(self, context):
        if not LAST["text"]:
            self.report({"WARNING"}, "Отчёта ещё нет: нажмите «Проверить модель»")
            return {"CANCELLED"}
        if copy_to_clipboard(LAST["text"]):
            self.report({"INFO"}, "Отчёт скопирован в буфер обмена (%d строк)" % len(LAST["text"].splitlines()))
            return {"FINISHED"}
        self.report({"WARNING"}, "Не удалось записать в буфер обмена: откройте отчёт кнопкой «В Text» и скопируйте из редактора")
        return {"CANCELLED"}


class EC_OT_open_report(bpy.types.Operator):
    bl_idname = "ec.open_report"
    bl_label = "Открыть в Text"
    bl_description = "Открывает последний отчёт в новом окне с редактором Text (можно выделять и копировать)"

    def execute(self, context):
        if not LAST["text"]:
            self.report({"WARNING"}, "Отчёта ещё нет: нажмите «Проверить модель»")
            return {"CANCELLED"}
        if open_text_window(LAST["block"]):
            return {"FINISHED"}
        self.report({"WARNING"}, "Окно не открылось. Отчёт в текстовом блоке %s: переключите любую область на Text Editor" % LAST["block"])
        return {"CANCELLED"}


class EC_OT_set_role(bpy.types.Operator):
    bl_idname = "ec.set_role"
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


class EC_OT_clear_role(bpy.types.Operator):
    bl_idname = "ec.clear_role"
    bl_label = "Удалить роль"
    bl_description = "Удаляет Custom Property role у выделенных объектов (и с данных меша, если роль попала туда по ошибке)"

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


class EC_OT_add_buffers(bpy.types.Operator):
    bl_idname = "ec.add_buffers"
    bl_label = "Создать пустышки буферов"
    bl_description = "Добавляет пустышки buffer_1...buffer_4 на оси буферов (Z=0, шаг по NEM 303, торцы кузова). Уже назначенные роли не дублируются"

    def execute(self, context):
        made, err = add_buffer_empties(context.scene)
        if err:
            self.report({"ERROR"}, err)
            return {"CANCELLED"}
        self.report({"INFO"}, "Создано: %s" % (", ".join(made) if made else "ничего (роли buffer_1...buffer_4 уже есть)"))
        return {"FINISHED"}


class EC_OT_make_uvs(bpy.types.Operator):
    bl_idname = "ec.make_uvs"
    bl_label = "Создать UV1/UV2"
    bl_description = "Кузову и вложенным мешам доводит UV-карты до двух: UV1 (Smart UV Project, если карт нет) и UV2 (Lightmap Pack, без перекрытий, для кисти). Существующие карты не трогает"

    def execute(self, context):
        made, problems = ensure_uvs(context.scene)
        if problems:
            self.report({"WARNING"}, "Не удалось: %s" % "; ".join(problems))
        else:
            self.report({"INFO"}, "Создано: %s" % ("; ".join(made) if made else "ничего (у всех мешей уже две карты и больше)"))
        return {"FINISHED"}


class EC_OT_pack_uv2(bpy.types.Operator):
    bl_idname = "ec.pack_uv2"
    bl_label = "UV2: общий атлас"
    bl_description = ("Все меши модели: вторая UV-карта (UV2) получает одну плотность текселей и упаковывается в один общий лист без перекрытий. "
                      "Нужно кисти Library: слой краски один на всю модель. Сначала «Применить трансформы» и «Создать UV1/UV2». Меняет только UV2")

    def execute(self, context):
        n, problems = pack_shared_uv2(context.scene)
        if problems:
            self.report({"WARNING"}, "Не удалось: %s" % "; ".join(problems))
            return {"CANCELLED"}
        self.report({"INFO"}, "UV2 упакована в общий атлас: мешей %d. Экспортируйте модель заново и проверьте её (кнопка проверки или glb_preflight.py --brush)" % n)
        return {"FINISHED"}


class EC_OT_trim_uvs(bpy.types.Operator):
    bl_idname = "ec.trim_uvs"
    bl_label = "Убрать лишние UV"
    bl_description = "Оставляет у мешей модели только первые две UV-карты (игра использует две)"

    def execute(self, context):
        done = trim_uvs(context.scene)
        self.report({"INFO"}, "Убрано: %s" % ("; ".join(done) if done else "ничего (карт не больше двух)"))
        return {"FINISHED"}


class EC_OT_prepare(bpy.types.Operator):
    bl_idname = "ec.prepare"
    bl_label = "Применить трансформы"
    bl_description = "Кузов: Apply All Transforms. Детали: только Rotation и Scale (Location не применяется, иначе потеряется origin шарнира)"

    def execute(self, context):
        notes = []
        err = prepare_transforms(context.scene, notes)
        if err:
            self.report({"ERROR"}, err)
            return {"CANCELLED"}
        if notes:
            self.report({"WARNING"}, "Трансформы применены, но пропущено %d: %s" % (len(notes), "; ".join(notes[:2])))
            print("\n".join(notes))
        else:
            self.report({"INFO"}, "Трансформы применены")
        return {"FINISHED"}


class EC_OT_static_body(bpy.types.Operator):
    bl_idname = "ec.static_body"
    bl_label = "Склеить статику в body"
    bl_description = ("Выделенные меши (неподвижные части кузова) копируются в коллекцию MODEL в позе текущего кадра "
                      "(трансформы родителей учтены) и склеиваются в один объект body с ролью body и origin в нуле мира. "
                      "Исходные объекты не меняются; повторный запуск заменяет прежний body")

    def execute(self, context):
        scene = context.scene
        meshes = [o for o in context.selected_objects if o.type == "MESH" and o.get("ec_copy") is None]
        if not meshes:
            self.report({"ERROR"}, "Выделите меши неподвижной части кузова")
            return {"CANCELLED"}
        for o in list(bpy.data.objects):
            if o.get("ec_copy") == "body":
                bpy.data.objects.remove(o, do_unlink=True)
        if find_body(scene):
            self.report({"ERROR"}, "В сцене уже есть объект с role = body (не от этого инструмента)")
            return {"CANCELLED"}
        if bpy.data.objects.get("body") is not None:
            self.report({"ERROR"}, "Объект с именем body уже есть: переименуйте его")
            return {"CANCELLED"}
        copies = static_copies(context, meshes, False)
        body = _join(context, copies)
        body.name = "body"
        body.data.name = "body"
        body["role"] = "body"
        body["ec_copy"] = "body"
        s = settings(scene)
        cs = [v.co for v in body.data.vertices]
        lo = [min(p[i] for p in cs) for i in range(3)]
        hi = [max(p[i] for p in cs) for i in range(3)]
        items = [("INFO", "Склеено мешей: %d, треугольников: %d" % (len(meshes), sum(len(p.vertices) - 2 for p in body.data.polygons)), None),
                 ("INFO", "Габарит: ширина (X) %.3f, длина (Y) %.3f, высота (Z) %.3f; Z от %.3f до %.3f" % (hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2], lo[2], hi[2]), None)]
        cx, cy = (hi[0] + lo[0]) / 2, (hi[1] + lo[1]) / 2
        if abs(cx) > 0.05 or abs(cy) > 0.05:
            items.append(("WARN", "Центр габарита смещён (X %.3f, Y %.3f): сдвиньте корень исходной модели на (%.3f, %.3f, 0) и склейте заново" % (cx, cy, -cx, -cy), None))
        if abs(lo[2] + s.buffer_h) > 0.1:
            items.append(("INFO", "Низ статики на Z %.3f, головка рельса на Z %.3f: колёса и рама могут быть выше низа" % (lo[2], -s.buffer_h), None))
        text = format_report(items)
        publish_report("Статика в body", text, REPORT_TEXT)
        print(text)
        self.report({"INFO"}, "Создан body в коллекции %s" % MODEL_COLLECTION)
        return {"FINISHED"}


class EC_OT_clean_copy(bpy.types.Operator):
    bl_idname = "ec.clean_copy"
    bl_label = "Чистые копии мешей"
    bl_description = ("Каждый выделенный меш копируется в коллекцию MODEL в позе текущего кадра: без родителей, анимации, поворота и масштаба "
                      "(колёсные пары ставьте на кадр 0). Имя берётся у пустышки-родителя, если меш в ней один")

    def execute(self, context):
        s = settings(context.scene)
        meshes = [o for o in context.selected_objects if o.type == "MESH" and o.get("ec_copy") is None]
        if not meshes:
            self.report({"ERROR"}, "Выделите меши (колёсные пары, рамы тележек)")
            return {"CANCELLED"}
        copies = static_copies(context, meshes, s.copy_center)
        bodies = find_body(context.scene)
        kids = ""
        if len(bodies) == 1:
            for c in copies:
                _adopt(c, bodies[0])
            kids = ", дети body"
        self.report({"INFO"}, "Копий: %d%s (%s)" % (len(copies), kids, ", ".join(o.name for o in copies[:6])))
        return {"FINISHED"}


class EC_OT_make_unit(bpy.types.Operator):
    bl_idname = "ec.make_unit"
    bl_label = "Узел из выделенных колёс"
    bl_description = ("Выделенные колёсные пары (меши, origin в центре оси, детьми body) собираются в узел тележки: создаётся пустышка unit_<n> "
                      "посередине между крайними осями на высоте оси, колёса становятся её детьми с ролями wheel_<n>_<k> и свойством radius "
                      "(из высоты оси). Если включена галка, активный объект это рама узла (role frame_<n>). Один узел это один радиус колёс")

    def execute(self, context):
        scene = context.scene
        s = settings(scene)
        bodies = find_body(scene)
        if len(bodies) != 1:
            self.report({"ERROR"}, "Нужен ровно один объект с role = body")
            return {"CANCELLED"}
        body = bodies[0]
        sel = [o for o in context.selected_objects if o.type == "MESH" and o is not body]
        frame = None
        act = context.view_layer.objects.active
        if s.unit_frame and act in sel:
            frame = act
            sel.remove(act)
        if not sel:
            self.report({"ERROR"}, "Выделите колёсные пары (меши)")
            return {"CANCELLED"}
        busy = [o.name for o in sel if WHEEL_ROLE_RE.match(role_of(o) or "")]
        if busy:
            self.report({"ERROR"}, "Уже в узле: %s. Уберите роль или удалите узел" % ", ".join(busy[:4]))
            return {"CANCELLED"}
        n = next_unit_number([role_of(o) or "" for o in scene.objects])
        inv_b = body.matrix_world.inverted()
        items = []
        rows = []
        for w in sel:
            rel = inv_b @ w.matrix_world
            a_, b_ = world_bbox(w)
            rows.append((rel.translation.y, rel.translation, (b_[2] - a_[2]) / 2.0, w))
        rows.sort(key=lambda t: t[0])
        rads = []
        for y, loc, half, w in rows:
            r = axle_radius(loc.z, s.buffer_h)
            rads.append(r)
            fl = half - r
            if fl < -0.01 or fl > FLANGE_DEPTH + 0.01:
                items.append(("WARN", "'%s': половина высоты меша %.3f при радиусе %.3f (реборда %.3f, ожидается 0..%.2f): проверьте origin (центр оси) и положение по Z" %
                              (w.name, half, r, fl, FLANGE_DEPTH), None))
            if abs(loc.x) > 0.02:
                items.append(("WARN", "'%s': origin смещён по X на %.3f, пара должна стоять по центру колеи" % (w.name, loc.x), None))
        if max(rads) - min(rads) > 0.01 * max(rads):
            items.append(("WARN", "Колёса разного радиуса (%s): один узел это один радиус, разделите на узлы" % ", ".join("%.3f" % r for r in rads), None))
        r_mean = sum(rads) / len(rads)
        c, offs, _ = unit_layout([t[0] for t in rows])
        z_mean = sum(t[1].z for t in rows) / len(rows)
        unit = bpy.data.objects.new("unit_%d" % n, None)
        unit.empty_display_type = "PLAIN_AXES"
        unit.empty_display_size = 0.5
        coll = body.users_collection[0] if body.users_collection else scene.collection
        coll.objects.link(unit)
        unit.parent = body
        unit.location = (0.0, c, z_mean)
        unit["role"] = "unit_%d" % n
        for k, (y, loc, half, w) in enumerate(rows):
            _adopt(w, unit)
            w["role"] = "wheel_%d_%d" % (n, k + 1)
            w["radius"] = round(rads[k], 3)
        if frame is not None:
            _adopt(frame, unit)
            frame["role"] = "frame_%d" % n
        items.insert(0, ("INFO", unit_draft_text(unit.name, unit_draft(c, [t[0] for t in rows], r_mean)), None))
        items.insert(1, ("INFO", "Узел %s: колёс %d, роли wheel_%d_1..wheel_%d_%d, radius по высоте оси%s" %
                         (unit.name, len(rows), n, n, len(rows), ", рама %s" % frame.name if frame is not None else ""), None))
        text = format_report(items)
        publish_report("Узел тележки", text, REPORT_TEXT)
        print(text)
        e, w_, i_ = summarize(items)
        self.report({"WARNING"} if w_ else {"INFO"}, "Узел %s создан. WARN %d" % (unit.name, w_))
        return {"FINISHED"}


class EC_OT_linear_keys(bpy.types.Operator):
    bl_idname = "ec.linear_keys"
    bl_label = "Ключи → Linear"
    bl_description = "Ставит интерполяцию Linear всем ключам действий кузова и его потомков (плавность хода даёт игра)"

    def execute(self, context):
        bodies = find_body(context.scene)
        if len(bodies) != 1:
            self.report({"ERROR"}, "Нужен ровно один объект с role = body")
            return {"CANCELLED"}
        acts = []
        for o in [bodies[0]] + list(bodies[0].children_recursive):
            for a in object_actions(o):
                if a not in acts:
                    acts.append(a)
        for a in acts:
            set_linear(a)
        self.report({"INFO"}, "Действий: %d (%s)" % (len(acts), ", ".join(a.name for a in acts[:5])))
        return {"FINISHED"}


class EC_OT_parent_body(bpy.types.Operator):
    bl_idname = "ec.parent_body"
    bl_label = "Выделенное: детьми body"
    bl_description = "Делает выделенные объекты потомками body с сохранением положения (как Ctrl+P, Keep Transform, но без ручного выбора родителя)"

    def execute(self, context):
        bodies = find_body(context.scene)
        if len(bodies) != 1:
            self.report({"ERROR"}, "Нужен ровно один объект с role = body")
            return {"CANCELLED"}
        body = bodies[0]
        n = 0
        for o in context.selected_objects:
            if o is body or o.parent is body:
                continue
            _adopt(o, body)
            n += 1
        self.report({"INFO"}, "Детьми body: %d" % n)
        return {"FINISHED"}


class EC_OT_bake_cycle(bpy.types.Operator):
    bl_idname = "ec.bake_cycle"
    bl_label = "Нормализовать привод колеса"
    bl_description = ("Выделите детали привода (шатуны, дышла, парораспределение), последним активным сделайте колесо с анимацией оборота. "
                      "Детали пересоберутся чистыми детьми кузова (в покое без поворота и масштаба), движение запечётся "
                      "в замкнутый цикл mech_<id> на оборот колеса (нужен Blender 4.4+)")

    def execute(self, context):
        s = settings(context.scene)
        bodies = find_body(context.scene)
        if len(bodies) != 1:
            self.report({"ERROR"}, "Нужен ровно один объект с role = body")
            return {"CANCELLED"}
        wheel = context.view_layer.objects.active
        err, items = bake_drive_cycle(context, bodies[0], wheel, list(context.selected_objects), s.cycle_id)
        if err:
            items = [("ERROR", err, None)] + items
        text = format_report(items)
        copied = publish_report("Привод колеса", text, REPORT_TEXT)
        print(text)
        if err:
            self.report({"ERROR"}, err)
            return {"CANCELLED"}
        e, w, i = summarize(items)
        self.report({"WARNING"} if w else {"INFO"}, "Цикл привода готов. WARN %d. %s" % (w, "Отчёт скопирован в буфер обмена" if copied else "Отчёт в тексте EC_report"))
        return {"FINISHED"}


class EC_OT_refs(bpy.types.Operator):
    bl_idname = "ec.refs"
    bl_label = "Эталон: рельсы и колёсные пары"
    bl_description = "Создаёт два рельса-бокса (внутренние грани на расстоянии колеи, верх на Z = -высота буферов) и колёсные пары (два колеса и ось) заданного диаметра; в экспорт не попадают"

    def execute(self, context):
        s = settings(context.scene)
        try:
            ys = [float(v) for v in s.wheel_ys.replace(";", ",").split(",") if v.strip()]
        except ValueError:
            self.report({"ERROR"}, "Колёсные пары по Y: числа через запятую")
            return {"CANCELLED"}
        rails, sets = make_refs(context.scene, s.buffer_h, s.wheel_d, ys, s.gauge)
        self.report({"INFO"}, "Эталон создан: %d рельса и %d колёсных пар (коллекция %s)" % (rails, sets, REF_COLLECTION))
        return {"FINISHED"}


class EC_OT_mech_key(bpy.types.Operator):
    bl_idname = "ec.mech_key"
    bl_label = "Ключ механизма"
    bl_description = "Покой: ключ на кадре 0, действие получает имя mech_<id> и свойство mech_id. Рабочее: ключ на кадре «Кадров хода» + 1 (сначала сдвиньте деталь в рабочее положение)"
    rest: BoolProperty(default=True)

    def execute(self, context):
        obj = context.active_object
        s = settings(context.scene)
        if obj is None or role_of(obj) is None:
            self.report({"ERROR"}, "Выберите деталь с ролью (role)")
            return {"CANCELLED"}
        if not re.match(r"^[a-z][a-z0-9_]*$", s.mech_id):
            self.report({"ERROR"}, "Id механизма: a-z, 0-9, _")
            return {"CANCELLED"}
        if self.rest and mech_id_taken(context.scene, obj, s.mech_id):
            self.report({"ERROR"}, "Id '%s' уже занят объектом '%s' (действие mech_%s). Задайте другой Id: у каждого механизма своё действие" %
                        (s.mech_id, mech_id_taken(context.scene, obj, s.mech_id), s.mech_id))
            return {"CANCELLED"}
        frame = 0 if self.rest else 1 + s.mech_frames
        if mech_key(context.scene, obj, s.mech_id, frame, self.rest) is None:
            self.report({"ERROR"}, "Ключ не создан")
            return {"CANCELLED"}
        if not self.rest:
            context.scene.frame_end = max(context.scene.frame_end, frame)
        self.report({"INFO"}, "Ключ на кадре %d (%s)" % (frame, "покой" if self.rest else "рабочее положение"))
        return {"FINISHED"}


class EC_OT_mech_id_from_action(bpy.types.Operator):
    bl_idname = "ec.mech_id_from_action"
    bl_label = "Взять Id из действия"
    bl_description = "Подставляет в поле «Id механизма» id активного объекта: из имени его действия mech_<id> или из свойства mech_id"

    def execute(self, context):
        mid = object_mech_id(context.active_object)
        if not mid:
            self.report({"WARNING"}, "У активного объекта нет действия mech_<id>")
            return {"CANCELLED"}
        settings(context.scene).mech_id = mid
        self.report({"INFO"}, "Id механизма: %s" % mid)
        return {"FINISHED"}


class EC_OT_export(bpy.types.Operator):
    bl_idname = "ec.export"
    bl_label = "Экспорт .glb"
    bl_description = "Проверка, экспорт кузова с потомками и проверка готового файла (glb_preflight). Отчёт в панели, буфере обмена и тексте EC_preflight"

    def execute(self, context):
        s = settings(context.scene)
        path = bpy.path.abspath(s.export_path) if s.export_path else default_export_path(s)
        ok, msg, rep = do_export(context.scene, path, s.kind, s.buffer_h, s.brush)
        copied = publish_report("Экспорт: " + msg, (msg + "\n\n" + rep) if rep else msg, PREFLIGHT_TEXT)
        print(msg)
        print(rep)
        self.report({"INFO"} if ok else {"ERROR"}, msg + (". Отчёт скопирован в буфер обмена" if copied else ""))
        return {"FINISHED"} if ok else {"CANCELLED"}


class EC_PT_panel(bpy.types.Panel):
    bl_label = "EC: модель для игры"
    bl_idname = "EC_PT_panel"
    bl_space_type = "VIEW_3D"
    bl_region_type = "UI"
    bl_category = "EC"

    def draw(self, context):
        lay = self.layout
        s = settings(context.scene)
        col = lay.column(align=True)
        col.prop(s, "kind")
        col.prop(s, "model_id")
        col.prop(s, "buffer_h")
        col.prop(s, "brush")
        lay.operator("ec.check", icon="CHECKMARK")

        box = lay.box()
        box.label(text="1. Роли")
        box.prop(s, "role_preset", text="")
        op = box.operator("ec.set_role", text="Назначить из шаблона")
        op.use_preset = True
        box.prop(s, "role")
        op = box.operator("ec.set_role", text="Назначить свою")
        op.use_preset = False
        box.operator("ec.clear_role", icon="X")
        box.operator("ec.add_buffers", icon="EMPTY_AXIS")

        box = lay.box()
        box.label(text="2. Подготовка")
        box.operator("ec.prepare", icon="OBJECT_ORIGIN")
        row = box.row(align=True)
        row.operator("ec.make_uvs", icon="UV")
        row.operator("ec.trim_uvs", icon="TRASH")
        box.operator("ec.pack_uv2", icon="UV")
        col = box.column(align=True)
        col.prop(s, "wheel_d")
        col.prop(s, "gauge")
        col.prop(s, "wheel_ys")
        box.operator("ec.refs", icon="MESH_CYLINDER")

        box = lay.box()
        box.label(text="3. Механизм (анимация)")
        ao = context.active_object
        if ao is None:
            box.label(text="Активный объект: нет", icon="OBJECT_DATA")
        else:
            cur = object_mech_id(ao)
            box.label(text="Активный: %s (роль %s)" % (ao.name, role_of(ao) or "нет"), icon="OBJECT_DATA")
            acts = [a.name for a in object_actions(ao)]
            box.label(text="Действие: %s" % (", ".join(acts) if acts else "нет"), icon="ACTION")
            if cur:
                box.label(text="Id механизма объекта: %s" % cur, icon="CHECKMARK")
        row = box.row(align=True)
        row.prop(s, "mech_id")
        row.operator("ec.mech_id_from_action", text="", icon="EYEDROPPER")
        box.prop(s, "mech_frames")
        row = box.row(align=True)
        op = row.operator("ec.mech_key", text="Ключ: покой")
        op.rest = True
        op = row.operator("ec.mech_key", text="Ключ: рабочее")
        op.rest = False
        box.separator()
        box.label(text="Из чужой модели (Sketchfab и т. п.)")
        box.operator("ec.static_body", icon="MESH_DATA")
        row = box.row(align=True)
        row.operator("ec.clean_copy", icon="DUPLICATE")
        row.prop(s, "copy_center", text="", icon="PIVOT_BOUNDBOX")
        box.operator("ec.parent_body", icon="OUTLINER_OB_GROUP_INSTANCE")
        box.separator()
        box.label(text="Узлы тележек (колёса и рамы)")
        box.prop(s, "unit_frame")
        box.operator("ec.make_unit", icon="EMPTY_AXIS")
        box.separator()
        box.label(text="Привод колеса (цикл на оборот)")
        box.prop(s, "cycle_id")
        box.operator("ec.bake_cycle", icon="ACTION")
        box.operator("ec.linear_keys", icon="IPO_LINEAR")

        box = lay.box()
        box.label(text="4. Экспорт")
        box.prop(s, "models_dir")
        box.prop(s, "export_path")
        box.operator("ec.export", icon="EXPORT")

        if LAST["text"]:
            box = lay.box()
            box.label(text=LAST["title"] or "Последний отчёт")
            row = box.row(align=True)
            row.operator("ec.show_report", text="Показать", icon="TEXT")
            row.operator("ec.copy_report", text="Копировать", icon="COPYDOWN")
            row.operator("ec.open_report", text="В Text", icon="WINDOW")
            col = box.column(align=True)
            col.prop(s, "wrap")
            col.prop(s, "show_info")
            order = {"ERROR": 0, "WARN": 1, "INFO": 2, "SUMMARY": 3}
            for lv, tx in sorted(LAST["lines"], key=lambda x: order[x[0]]):
                if lv == "INFO" and not s.show_info:
                    continue
                draw_wrapped(box, lv, tx, s.wrap)


CLASSES = (ECSettings, EC_OT_check, EC_OT_show_report, EC_OT_copy_report, EC_OT_open_report, EC_OT_set_role, EC_OT_clear_role, EC_OT_add_buffers,
           EC_OT_prepare, EC_OT_static_body, EC_OT_clean_copy, EC_OT_parent_body, EC_OT_make_unit, EC_OT_linear_keys, EC_OT_bake_cycle, EC_OT_make_uvs, EC_OT_pack_uv2, EC_OT_trim_uvs, EC_OT_refs, EC_OT_mech_key, EC_OT_mech_id_from_action, EC_OT_export, EC_PT_panel)


def register():
    for c in CLASSES:
        bpy.utils.register_class(c)
    bpy.types.Scene.ec_tools = PointerProperty(type=ECSettings)
    if _load_post not in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.append(_load_post)
    subscribe_active_object()


def unregister():
    try:
        bpy.msgbus.clear_by_owner(_MSGBUS_OWNER)
    except Exception:
        pass
    if _load_post in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.remove(_load_post)
    del bpy.types.Scene.ec_tools
    for c in reversed(CLASSES):
        bpy.utils.unregister_class(c)


# ---------------------------------------------------------------- командная строка

def _cli(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="ec_model_tools")
    ap.add_argument("cmd", choices=["check", "export"])
    ap.add_argument("--id", default="")
    ap.add_argument("--kind", choices=["trains", "buildings"], default="trains")
    ap.add_argument("--buffer-h", type=float, default=BUFFER_H)
    ap.add_argument("--brush", action="store_true")
    ap.add_argument("--models-dir", default=DEFAULT_MODELS_DIR, help="папка моделей игры (по умолчанию %s)" % DEFAULT_MODELS_DIR)
    ap.add_argument("--out", default="", help="путь .glb (по умолчанию <папка моделей>/<id>/<id>.glb)")
    a = ap.parse_args(argv)
    scene = bpy.context.scene
    if a.cmd == "check":
        items = check_model(scene, a.buffer_h, a.kind, a.brush)
        print(format_report(items))
        return 1 if any(lv == "ERROR" for lv, _, _ in items) else 0
    path = a.out
    if not path:
        class _S:  # минимальная замена настроек панели; id по умолчанию берётся из имени файла .blend
            model_id, kind, models_dir = a.id, a.kind, a.models_dir
        path = default_export_path(_S)
    ok, msg, rep = do_export(scene, path, a.kind, a.buffer_h, a.brush)
    print(msg)
    print(rep)
    return 0 if ok else 1


if __name__ == "__main__":
    if "--" in sys.argv and bpy.app.background:
        sys.exit(_cli(sys.argv[sys.argv.index("--") + 1:]))
    register()
