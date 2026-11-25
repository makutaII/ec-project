#!/usr/bin/env python3
"""Проверка математики цикла привода (tools/blender/ec_model_tools.py, блок drive-cycle-math) без Blender:  python tools/test_drive_cycle.py

Блок между маркерами `# >>> drive-cycle-math` и `# <<< drive-cycle-math` вынимается из файла и исполняется отдельно (модуль целиком требует bpy).
Что проверяется:
1. Пересборка детали: вершины меша в матрице u и узел с положением loc[k] и поворотом quat[k] дают те же мировые координаты, что исходный объект
   на каждом кадре (родитель с поворотом 90° и масштабом, собственный поворот покоя и масштаб, в том числе зеркальный).
2. Шаг колеса и число кадров на оборот, направление (качение вперёд это отрицательный поворот вокруг +X).
3. Порядок кадров цикла: замыкающий кадр равен нулевому, при обратном вращении порядок разворачивается.
4. Непрерывность знака кватерниона на полном обороте, роли деталей.
"""
import math
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "blender", "ec_model_tools.py")

fails = []


def check(label, ok, extra=""):
    print(("PASS " if ok else "FAIL ") + label + ("" if ok else "  " + str(extra)))
    if not ok:
        fails.append(label)


text = open(SRC, encoding="utf-8").read()
a = text.index("# >>> drive-cycle-math")
b = text.index("# <<< drive-cycle-math")
ns = {"math": math, "re": re}
exec(compile(text[a:b], SRC + "#drive-cycle-math", "exec"), ns)
ua = text.index("# >>> unit-math")
ub = text.index("# <<< unit-math")
exec(compile(text[ua:ub], SRC + "#unit-math", "exec"), ns)


# ---- мелкая матричная арифметика (списки строк)
def mm(x, y):
    return [[sum(x[r][k] * y[k][c] for k in range(len(y))) for c in range(len(y[0]))] for r in range(len(x))]


def rot(axis, deg):
    t = math.radians(deg)
    c, s = math.cos(t), math.sin(t)
    if axis == "x":
        return [[1, 0, 0], [0, c, -s], [0, s, c]]
    if axis == "y":
        return [[c, 0, s], [0, 1, 0], [-s, 0, c]]
    return [[c, -s, 0], [s, c, 0], [0, 0, 1]]


def m4(r3, t=(0, 0, 0), scale=(1, 1, 1)):
    m = [[r3[r][c] * scale[c] for c in range(3)] + [t[r]] for r in range(3)]
    return m + [[0, 0, 0, 1]]


def apply4(m, v):
    return [sum(m[r][c] * v[c] for c in range(3)) + m[r][3] for r in range(3)]


def quat_rot(q):
    w, x, y, z = q
    return [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]


def close(p, q, tol=1e-9):
    return all(abs(x - y) <= tol for x, y in zip(p, q))


def part_worlds(parent, rest_rot, scale, n, step_deg=7.5):
    """Мировые матрицы детали: родитель * (смещение по кругу + поворот вокруг оси X детали) * поворот покоя * масштаб"""
    out = []
    for f in range(n):
        ang = step_deg * f
        local_t = (0.3 * math.cos(math.radians(ang)), 0.1 * f / n, 0.3 * math.sin(math.radians(ang)))
        local = m4(mm(rot("y", -ang * 0.5), rest_rot), local_t, scale)
        out.append(mm(parent, local))
    return out


def reconstruct_error(worlds, tr):
    rnd = random.Random(7)
    err = 0.0
    for f, w in enumerate(worlds):
        node = m4(quat_rot(tr["quat"][f]), tr["loc"][f])
        for _ in range(20):
            v = [rnd.uniform(-2, 2) for _ in range(3)]
            lhs = apply4(w, v)
            u_v = [sum(tr["u"][r][c] * v[c] for c in range(3)) for r in range(3)]
            rhs = apply4(node, u_v)
            err = max(err, max(abs(x - y) for x, y in zip(lhs, rhs)))
    return err


# ---- 1. пересборка детали
parent = m4(mm(rot("z", 90), rot("x", 3)), (1.0, 2.0, -1.052), (1.191, 1.191, 1.191))
rest = mm(rot("z", 34.31), rot("x", 10))
wl = part_worlds(parent, rest, (0.939, 0.939, 0.939), 49)
tr = ns["track_from_worlds"](wl)
check("деталь: мировые координаты совпадают на всех кадрах", reconstruct_error(wl, tr) < 1e-9, reconstruct_error(wl, tr))
check("деталь: в покое поворот единичный", close(tr["quat"][0], (1, 0, 0, 0)), tr["quat"][0])
check("деталь: масштаб не менялся", tr["scale_dev"] < 1e-9, tr["scale_dev"])
check("деталь: оси не перекошены", tr["skew"] < 1e-9, tr["skew"])

wl_m = part_worlds(parent, rest, (-0.9, 0.9, 0.9), 49)
tr_m = ns["track_from_worlds"](wl_m)
check("зеркальная деталь: координаты совпадают", reconstruct_error(wl_m, tr_m) < 1e-9, reconstruct_error(wl_m, tr_m))
det_u = (tr_m["u"][0][0] * (tr_m["u"][1][1] * tr_m["u"][2][2] - tr_m["u"][2][1] * tr_m["u"][1][2])
         - tr_m["u"][0][1] * (tr_m["u"][1][0] * tr_m["u"][2][2] - tr_m["u"][2][0] * tr_m["u"][1][2])
         + tr_m["u"][0][2] * (tr_m["u"][1][0] * tr_m["u"][2][1] - tr_m["u"][2][0] * tr_m["u"][1][1]))
check("зеркальная деталь: определитель u отрицателен (в Blender нужен flip_normals)", det_u < 0, det_u)

wl_s = part_worlds(parent, rest, (0.939, 0.939, 0.939), 10)
wl_s[5] = mm(wl_s[5], m4(rot("x", 0), (0, 0, 0), (1.2, 1.2, 1.2)))
check("анимация масштаба замечается", ns["track_from_worlds"](wl_s)["scale_dev"] > 0.1)

wl_k = part_worlds(parent, rest, (0.939, 0.939, 0.939), 5)
wl_k = [mm(w, m4([[1, 0.3, 0], [0, 1, 0], [0, 0, 1]])) for w in wl_k]
check("перекос осей замечается", ns["track_from_worlds"](wl_k)["skew"] > 0.1)

# деталь-пустышка с мешем внутри: меш переводится матрицей «мир кадра 0 без переноса шарнира»
local_child = m4(mm(rot("z", 12), rot("x", 80)), (0.4, -0.2, 0.15), (0.95, 0.95, 0.95))
child_w = [mm(w, local_child) for w in wl]
t0 = tr["loc"][0]
mg = [row[:3] + [row[3] - t0[r]] for r, row in enumerate(child_w[0][:3])]
err_c = 0.0
rnd_c = random.Random(11)
for f in range(len(wl)):
    node = m4(quat_rot(tr["quat"][f]), tr["loc"][f])
    for _ in range(20):
        v = [rnd_c.uniform(-2, 2) for _ in range(3)]
        mv = apply4(mg + [[0, 0, 0, 1]], v)
        err_c = max(err_c, max(abs(p - q) for p, q in zip(apply4(child_w[f], v), apply4(node, mv))))
check("пустышка с мешем: геометрия внутри совпадает на всех кадрах", err_c < 1e-9, err_c)

# непрерывность знака на полном обороте
spin = [m4(rot("x", -7.5 * f)) for f in range(49)]
q = ns["track_from_worlds"](spin)["quat"]
check("знак кватерниона непрерывен на обороте", all(ns["_qdot"](q[i], q[i + 1]) > 0 for i in range(len(q) - 1)))
check("замкнутый цикл: поворот последнего кадра равен нулевому", close(q[0], q[-1], 1e-9) or close(q[0], tuple(-x for x in q[-1]), 1e-9), (q[0], q[-1]))

# ---- 2. шаг колеса
fwd = [m4(rot("x", -7.5 * f), (0, 0, 0.9)) for f in range(2)]   # матрицы берутся относительно кузова (его оси это оси модели)
step, ax = ns["wheel_step"](fwd[0], fwd[1])
check("колесо вперёд: -7.5 градусов за кадр вокруг +X", abs(step + 7.5) < 1e-6 and ax > 0.99, (step, ax))
back = [m4(rot("x", 7.5 * f)) for f in range(2)]
step_b, _ = ns["wheel_step"](back[0], back[1])
check("колесо назад: +7.5", abs(step_b - 7.5) < 1e-6, step_b)
side = [m4(rot("y", 7.5 * f)) for f in range(2)]
check("ось не вдоль X замечается", ns["wheel_step"](side[0], side[1])[1] < 0.1)
check("оборот 48 кадров", ns["cycle_period"](-7.5) == 48 and ns["cycle_period"](7.5) == 48)
check("оборот 120 кадров при 3 градусах", ns["cycle_period"](3.0) == 120)
check("шаг не делит оборот: нет цикла", ns["cycle_period"](7.7) is None)
check("нулевой шаг: нет цикла", ns["cycle_period"](0.0) is None)

# ---- 3. порядок кадров
o_f = ns["cycle_order"](48, 48, False)
check("порядок вперёд: 0..47 и замыкающий 0", o_f[:3] == [0, 1, 2] and o_f[47] == 47 and o_f[48] == 0 and len(o_f) == 49, o_f)
o_b = ns["cycle_order"](48, 48, True)
check("порядок назад: 0, 47, 46, ... и замыкающий 0", o_b[:3] == [0, 47, 46] and o_b[47] == 1 and o_b[48] == 0, o_b)
check("кадров меньше оборота: нет порядка", ns["cycle_order"](40, 48, False) is None)
o_x = ns["cycle_order"](60, 48, False)
check("лишние исходные кадры отбрасываются", max(o_x) == 47 and len(o_x) == 49)

# сквозной случай: колесо и деталь по разворачиваемому порядку
wheel_w = [m4(rot("x", 7.5 * f)) for f in range(48)]
part_w = part_worlds(parent, rest, (0.939, 0.939, 0.939), 48)
st, _ = ns["wheel_step"](wheel_w[0], wheel_w[1])
order = ns["cycle_order"](48, ns["cycle_period"](st), st > 0)
tr_b = ns["track_from_worlds"]([part_w[i] for i in order])
check("обратное колесо: деталь по развёрнутому порядку воспроизводится",
      reconstruct_error([part_w[i] for i in order], tr_b) < 1e-9)
check("обратное колесо: замыкающий кадр равен нулевому", close(tr_b["loc"][0], tr_b["loc"][-1]))

# ---- 4. роли
check("роль: хвост дубля убирается", ns["drive_role"]("connecting_rod.001") == "drv_connecting_rod")
check("роль: пробелы и заглавные", ns["drive_role"]("Side Rod") == "drv_side_rod")
check("роль: подходит под правило имён", re.match(r"^[a-z][a-z0-9_]*$", ns["drive_role"]("123 Rod!")) is not None)

# ---- 5. узлы тележек
check("узел: первый номер 1, следующий свободный", ns["next_unit_number"](["body", "wheel_1_1"]) == 1 and ns["next_unit_number"](["unit_1", "unit_3", "x"]) == 4)
c, offs, skew = ns["unit_layout"]([6.0, 2.0, 4.0])
check("узел: центр между крайними осями, смещения по возрастанию", abs(c - 4.0) < 1e-9 and offs == [-2.0, 0.0, 2.0] and skew < 1e-9, (c, offs))
check("радиус по высоте оси", abs(ns["axle_radius"](-0.161, 1.061) - 0.9) < 1e-9)
d = ns["unit_draft"](4.0, [6.0, 2.0, 4.0], 0.9)
check("заготовка: Z Godot = -Y Blender, оси по возрастанию", abs(d["b_offset_z"] + 4.0) < 1e-9 and d["axles"] == [-2.0, 0.0, 2.0], d)
check("заготовка: три оси требуют axle_offsets", "axle_offsets" in ns["unit_draft_text"]("unit_2", d))
d2 = ns["unit_draft"](0.0, [-1.5, 1.5], 0.9)
check("заготовка: две симметричные оси дают wheel_pair_position", "wheel_pair_position = Vector3(0, 0.900, 1.500)" in ns["unit_draft_text"]("unit_1", d2))
check("роли узлов и колёс", ns["UNIT_RE"].match("unit_12") and ns["WHEEL_ROLE_RE"].match("wheel_2_3") and not ns["WHEEL_ROLE_RE"].match("wheel_2"))
check("допуск на реборду задан", 0.02 <= ns["FLANGE_DEPTH"] <= 0.1)

print()
print("FAIL: %d" % len(fails) if fails else "Все проверки пройдены")
sys.exit(1 if fails else 0)
