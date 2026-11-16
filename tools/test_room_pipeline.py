#!/usr/bin/env python3
"""Проверка пайплайна комнат без Blender и Godot (ATTN_25 RM7):  python tools/test_room_pipeline.py

1. Эталон из room_fixture.reference_scene даёт ERROR 0 и WARN 0, числа карточки равны 480 x 250 x 380 и так далее.
2. Каждая поломка из room_fixture.BROKEN даёт ожидаемую строку нужного уровня; поломка group_ctl (лампы одной группой) проходит.
3. Файл data/models/room_test_01/room_test_01.glb совпадает с тем, что пишет генератор (пересобрать: python tools/room_fixture.py <путь>).
Правила одни на Blender и glb_preflight (ec_room_tools.check_room), поэтому проверка файла проверяет и панель EC Room, кроме снятия сцены Blender.
"""
import contextlib
import io
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import glb_preflight as pf   # noqa: E402
import room_fixture as fx    # noqa: E402

fails = []


def check(label, ok, extra=""):
    print(("PASS " if ok else "FAIL ") + label + ("" if ok else "  " + extra))
    if not ok:
        fails.append(label)


def report(sc):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "room.glb")
        with open(path, "wb") as f:
            f.write(fx.to_glb(sc))
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = pf.run_room(path)
    return rc, buf.getvalue()


rc, out = report(fx.reference_scene())
check("эталон: код возврата 0", rc == 0, out)
check("эталон: ERROR 0, WARN 0", "Итог: ERROR 0, WARN 0" in out, out)
for needle in ("floor_y = -50.0", "size = Vector3(480.0, 250.0, 380.0)", "AABB(Vector3(-230.0, 3.0, -180.0), Vector3(460.0, 190.0, 360.0))",
               '"x": 0.0, "w": 170.0, "sill": 80.0, "h": 140.0', '"x": 100.0, "w": 80.0, "sill": 0.0, "h": 200.0',
               "Управляемых объектов: 3 (Observe: 2)", "anim_name = &\"mech_curtain\"", "направление (0.00, -1.00, 0.00)"):
    check("эталон: в отчёте «%s»" % needle, needle in out, out)

for name, (_, level, phrase) in sorted(fx.BROKEN.items()):
    rc, out = report(fx.broken_scene(name))
    if level == "OK":
        check("%s: проходит" % name, rc == 0 and "ERROR 0" in out, out)
        continue
    lines = [ln for ln in out.splitlines() if ln.startswith("[%s]" % level) and phrase in ln]
    check("%s: [%s] «%s»" % (name, level, phrase), bool(lines), out)
    if level == "ERROR":
        check("%s: код возврата 1" % name, rc == 1)

# длины в файле в сантиметрах (x100): коробка room_volume на 480 единиц шириной
g, _ = pf.load_gltf(os.path.join(HERE, "..", "data", "models", "room_test_01", "room_test_01.glb"))
vol = next(n for n in g["nodes"] if n["name"] == "room_volume")
mx = g["accessors"][g["meshes"][vol["mesh"]]["primitives"][0]["attributes"]["POSITION"]]["max"]
check("room_test_01.glb в сантиметрах: room_volume 480 единиц по X", abs(mx[0] * 2 - 480.0) < 0.01, str(mx))

ref = os.path.join(HERE, "..", "data", "models", "room_test_01", "room_test_01.glb")
if os.path.exists(ref):
    check("room_test_01.glb совпадает с генератором", open(ref, "rb").read() == fx.to_glb(fx.reference_scene()), "пересоберите: python tools/room_fixture.py data/models/room_test_01/room_test_01.glb")
else:
    check("room_test_01.glb существует", False)

print("\nИТОГ: %s" % ("OK" if not fails else "ПРОВАЛЕНО %d: %s" % (len(fails), "; ".join(fails))))
sys.exit(1 if fails else 0)
