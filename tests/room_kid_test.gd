extends Node

## ATTN_25 RM9: заготовка детской из .glb (data/models/room_kid_room_10, собрана tools/kid_room_gen.py).
## Запуск: открыть tests/room_kid_test.tscn и нажать F6. Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет, что детская из .glb сходится с процедурной (числа карточки, коллайдеры, колба, небо, потолок, детали) и работает
## с теми же механизмами комнаты (RoomRoot, GFX.lamp_changed, слои оболочки).

const ID := &"kid_room_10"

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _ready() -> void:
	print("== RM9: детская из .glb")
	var cfg := RoomCatalog.make(ID)
	check("карточка kid_room_10 со сценой", cfg != null and cfg.scene != null)
	if cfg == null or cfg.scene == null:
		_finish()
		return
	var room := RoomRoot.wrap(cfg.scene.instantiate())
	add_child(room)
	room.import_glb()
	check("роли .glb найдены, замечаний нет", room.glb.present and room.glb.warnings.is_empty(), str(room.glb.warnings))

	print("== Числа карточки = процедурная детская (умолчания RoomConfig)")
	var proc := RoomConfig.new()
	check("паспорт сходится со сценой", room.glb.diff(proc).is_empty(), str(room.glb.diff(proc)))
	check("паспорт карточки сходится со сценой", room.glb.diff(cfg).is_empty(), str(room.glb.diff(cfg)))

	print("== Коллизии")
	var bodies := 0
	for n in room.find_children("collider_*", "StaticBody3D", true, false):
		bodies += 1
		check("%s: слой room" % n.name, (n as StaticBody3D).collision_layer == Global.active_layers(["room"]))
	check("коллайдеров 10 (пол, 4 стены, кровать, стол, стул, шкаф, стеллаж)", bodies == 10, str(bodies))
	for nm in ["window_n", "door_s", "camera_bounds", "room_volume", "table_origin", "window_sun"]:
		check("служебного узла %s больше нет" % nm, room.find_child(nm, true, false) == null)

	print("== Группы, слои, потолок, детали")
	room.setup(1 << (Global.ROOM_VISUAL_LAYER - 1), 1 << (Global.ROOM_SHELL_LAYER - 1))
	var shell_bit := 1 << (Global.ROOM_SHELL_LAYER - 1)
	var vis_bit := 1 << (Global.ROOM_VISUAL_LAYER - 1)
	var wall := room.find_child("wall_w", true, false) as MeshInstance3D
	var rod := room.find_child("curtain_rod", true, false) as MeshInstance3D
	var bed := room.find_child("bed_frame", true, false) as MeshInstance3D
	var ceil := room.get_ceiling_mesh()
	check("стена и карниз в оболочке", wall != null and wall.layers == shell_bit and rod != null and rod.layers == shell_bit)
	check("кровать на visual layer комнаты", bed != null and bed.layers == vis_bit)
	check("потолок найден и в оболочке", ceil != null and ceil.layers == shell_bit)
	check("стены для тени и скрытия: больше 10 кусков", room.get_wall_meshes().size() > 10, str(room.get_wall_meshes().size()))
	room.set_detail(0)
	var t2 := room.group_nodes(&"decor_t2")
	var t3 := room.group_nodes(&"decor_t3")
	check("detail 0: T2 и T3 скрыты", t2.size() == 1 and t3.size() == 1 and not (t2[0] as Node3D).visible and not (t3[0] as Node3D).visible)
	room.set_detail(2)
	check("detail 2: все видны", (t2[0] as Node3D).visible and (t3[0] as Node3D).visible)

	print("== Колба и небо")
	var bulb := room.find_child("bulb_lamp", true, false) as MeshInstance3D
	check("колба с bulb_of = gfx_lamp", bulb != null and room.glb.bulbs.size() == 1 and room.glb.bulbs[0]["of"] == RoomGlb.GFX_LAMP)
	if bulb != null:
		var m := bulb.get_surface_override_material(0) as StandardMaterial3D
		check("колба: свой материал", m != null)
		if m != null:
			room.set_lamp_glow(false)
			check("лампа выключена: колба не светится", not m.emission_enabled)
			room.set_lamp_glow(true)
			check("лампа включена: колба светится", m.emission_enabled)
	var sky := room.find_child("sky_card", true, false) as MeshInstance3D
	check("небо в группе gfx_sky", sky != null and sky.is_in_group(&"gfx_sky"))
	if sky != null:
		var sm := sky.material_override as StandardMaterial3D
		check("небо: material_override с градиентом (GFX красит его)", sm != null and sm.albedo_texture is GradientTexture2D)
	var reg := RoomControlRegistry.collect(room, "kid_room_10")
	check("управлений нет, замечаний реестра нет", reg.defs.is_empty() and reg.warnings.is_empty(), str(reg.warnings))
	room.queue_free()
	_finish()


func _finish() -> void:
	print("")
	print("ИТОГ: OK" if _bad == 0 else "ИТОГ: ОШИБОК %d" % _bad)
