#!/usr/bin/env python3
"""Пустой куб для Blender-пайплайна (ATTN_25 RM9b): коробка 400 x 250 x 400 см без мебели, окна и двери, для текстур и импорта.
Заменяет процедурную комнату cube. Только оболочка (пол, потолок, 4 стены), коллайдеры, объём, границы камеры, table_origin.
Оси как в Godot (север -Z), пол на y = -50, стол на y = 0. Собирается без Blender, как tools/kid_room_gen.py.

    python tools/cube_room_gen.py data/models/room_cube/room_cube.glb
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import room_fixture as fx   # noqa: E402
import kid_room_gen as kg   # noqa: E402

SIZE = (400.0, 250.0, 400.0)
T = 10.0
FY = -50.0
BOUNDS = ((-190.0, 3.0, -190.0), (190.0, 193.0, 190.0))
WALL = kg.PALETTE["cream"]


def build_scene():
    b = kg.Builder(("Floor", "Ceiling", "Shell"))
    hx, hz = SIZE[0] / 2.0, SIZE[2] / 2.0
    b.box("Floor", "floor_slab", (SIZE[0] + 2 * T, T, SIZE[2] + 2 * T), (0.0, FY - T / 2.0, 0.0), "wood", kg.FLOOR_COLOR)
    b.box("Ceiling", "ceiling_slab", (SIZE[0] + 2 * T, T, SIZE[2] + 2 * T), (0.0, FY + SIZE[1] + T / 2.0, 0.0), "paint", kg.CEILING_COLOR)
    cy = FY + SIZE[1] / 2.0
    b.box("Shell", "wall_n", (SIZE[0] + 2 * T, SIZE[1], T), (0.0, cy, -(hz + T / 2.0)), "paint", WALL)
    b.box("Shell", "wall_s", (SIZE[0] + 2 * T, SIZE[1], T), (0.0, cy, hz + T / 2.0), "paint", WALL)
    b.box("Shell", "wall_w", (T, SIZE[1], SIZE[2]), (-(hx + T / 2.0), cy, 0.0), "paint", WALL)
    b.box("Shell", "wall_e", (T, SIZE[1], SIZE[2]), (hx + T / 2.0, cy, 0.0), "paint", WALL)

    box = {"shape": "box"}
    b.proxy("collider_floor", "collider", (-hx - T, FY - T, -hz - T), (hx + T, FY, hz + T), extras=box)
    b.proxy("collider_wall_n", "collider", (-hx - T, FY, -hz - T), (hx + T, FY + SIZE[1], -hz), extras=box)
    b.proxy("collider_wall_s", "collider", (-hx - T, FY, hz), (hx + T, FY + SIZE[1], hz + T), extras=box)
    b.proxy("collider_wall_w", "collider", (-hx - T, FY, -hz), (-hx, FY + SIZE[1], hz), extras=box)
    b.proxy("collider_wall_e", "collider", (hx, FY, -hz), (hx + T, FY + SIZE[1], hz), extras=box)
    b.proxy("camera_bounds", "camera_bounds", BOUNDS[0], BOUNDS[1])
    b.proxy("room_volume", "room_volume", (-hx, FY, -hz), (hx, FY + SIZE[1], hz))
    b.nodes.append(fx.node("table_origin", "Room", (0.0, 0.0, 0.0), extras={"role": "table_origin"}))

    mat_defs = {}
    for role, (nm, rough, metal) in kg.ROLES.items():
        if nm in b.mats:
            mat_defs[nm] = {"color": [1.0, 1.0, 1.0, 1.0], "roughness": rough, "metallic": metal}
    mat_defs["wood_kid"]["double_sided"] = False
    return {"nodes": b.nodes, "glb_scale": 1.0, "mat_defs": mat_defs}


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
