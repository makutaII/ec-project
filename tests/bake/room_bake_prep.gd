@tool
extends EditorScript

## ATTN_14 D2: пробный bake света комнаты (одно состояние: ночь + лампа над столом, directional lightmap со specular, Godot 4.8).
## Готовит сцену для bake из детской kid_room_10 и ничего в проекте не меняет, кроме папки tests/bake/out/ (она в .gitignore).
## Запуск: открыть файл в редакторе скриптов, File, Run (Ctrl+Shift+X). Дальше:
##   1. Сцена tests/bake/out/room_bake_trial.scn откроется сама. Выберите узел LightmapGI, нажмите «Bake Lightmaps» в верхней панели.
##   2. Когда bake закончится, откройте tests/bake/room_bake_run.tscn и нажмите F6: прогон «динамический свет» против «запечённый».
## Что делает скрипт: берёт сцену детской, убирает служебные боксы ролей (коллайдеры, окно, дверь, границы, объём, стрелка солнца),
## строит вторую развёртку (UV2, lightmap_unwrap) у видимых мешей и включает им GI Static (небо и ложный AO без GI), ставит лампу и луну ночного
## состояния со значениями GFX (bake_mode Static) и узел LightmapGI (directional, MEDIUM, 3 отскока, шумодав, probes для динамических предметов).
## Мебель в игре не двигается, а вагоны на столе остаются динамическими: lightmap их не касается, их освещают probes и динамический свет.

const ROOM_CARD := "res://data/rooms/cards/kid_room_10.tres"
const OUT_DIR := "res://tests/bake/out"
const OUT_SCENE := OUT_DIR + "/room_bake_trial.scn"
## Размер текселя lightmap, см (мир в сантиметрах: 5 см на тексель ≈ 0,5 МБ-атлас на комнату)
const TEXEL_CM := 5.0
## Роли служебных боксов: в bake не участвуют
const DROP_ROLES: Array[String] = ["collider", "window", "door", "camera_bounds", "room_volume", "window_sun", "table_origin"]
## Роли без GI (рисуются без освещения)
const NO_GI_ROLES: Array[String] = ["sky_card", "fake_ao"]


func _run() -> void:
	var card := load(ROOM_CARD) as RoomConfig
	if card == null or card.scene == null:
		push_error("room_bake_prep: нет карточки или сцены: %s" % ROOM_CARD)
		return
	var wrapper := card.scene.instantiate()
	if wrapper.get_child_count() == 0:
		push_error("room_bake_prep: в сцене комнаты нет модели .glb")
		wrapper.free()
		return
	var model := wrapper.get_child(0)
	wrapper.remove_child(model)
	wrapper.free()
	model.scene_file_path = ""   # узлы модели сохраняются прямо в сцену bake, а не ссылкой на .glb
	var root := Node3D.new()
	root.name = "BakeTrial"
	model.name = "Room"
	root.add_child(model)

	_drop_proxies(model)
	var counts := _prepare_meshes(model, Transform3D.IDENTITY)
	_add_table_and_wagon(root)
	_add_lights(root)
	_add_lightmap_gi(root)
	_set_owner(root, root)

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err != OK:
		push_error("room_bake_prep: pack не удался (код %d)" % err)
		root.free()
		return
	err = ResourceSaver.save(packed, OUT_SCENE)
	root.free()
	if err != OK:
		push_error("room_bake_prep: не записан %s (код %d)" % [OUT_SCENE, err])
		return
	print("room_bake_prep: записано %s. Мешей с UV2: %d, без GI: %d, не развёрнуто: %d" % [OUT_SCENE, counts.uv2, counts.no_gi, counts.failed])
	EditorInterface.open_scene_from_path(OUT_SCENE)
	print("room_bake_prep: дальше выберите узел LightmapGI и нажмите «Bake Lightmaps», потом F6 на tests/bake/room_bake_run.tscn")


static func _role(n: Node) -> String:
	if n.has_meta("extras"):
		var ex: Variant = n.get_meta("extras")
		if ex is Dictionary:
			return str((ex as Dictionary).get("role", ""))
	return ""


func _drop_proxies(n: Node) -> void:
	for c in n.get_children():
		if _role(c) in DROP_ROLES:
			n.remove_child(c)
			c.free()
		else:
			_drop_proxies(c)


## UV2 и GI Static у мешей. xform: накопленный transform от корня комнаты (lightmap_unwrap учитывает масштаб)
func _prepare_meshes(n: Node, xform: Transform3D) -> Dictionary:
	var counts := {"uv2": 0, "no_gi": 0, "failed": 0}
	var t := xform
	if n is Node3D:
		t = xform * (n as Node3D).transform
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if _role(mi) in NO_GI_ROLES:
			mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
			counts.no_gi += 1
		elif mi.mesh is ArrayMesh:
			var am := (mi.mesh as ArrayMesh).duplicate() as ArrayMesh
			if am.lightmap_unwrap(t, TEXEL_CM) == OK:
				mi.mesh = am
				mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
				counts.uv2 += 1
			else:
				push_warning("room_bake_prep: '%s': lightmap_unwrap не удался" % mi.name)
				counts.failed += 1
	for c in n.get_children():
		var sub := _prepare_meshes(c, t)
		for k in counts:
			counts[k] += sub[k]
	return counts


## Стол и вагон-заглушка: стол запекается (статика), вагон динамический (его освещают probes)
func _add_table_and_wagon(root: Node3D) -> void:
	var table := MeshInstance3D.new()
	table.name = "TableStub"
	var tm := BoxMesh.new()
	tm.size = Vector3(200.0, 5.0, 100.0)
	table.mesh = tm
	table.position = Vector3(0.0, -2.5, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.62, 0.50, 0.38)
	mat.roughness = 0.9
	table.material_override = mat
	root.add_child(table)
	(table.mesh as BoxMesh).add_uv2 = true
	table.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	var wagon := MeshInstance3D.new()
	wagon.name = "WagonStub"
	var wm := BoxMesh.new()
	wm.size = Vector3(30.0, 8.0, 7.0)
	wagon.mesh = wm
	wagon.position = Vector3(20.0, 4.0, 10.0)
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = Color(0.85, 0.2, 0.18)
	wmat.roughness = 0.4
	wagon.material_override = wmat
	wagon.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	root.add_child(wagon)


## Ночь + лампа: значения TimeOfDayPreset night и лампы GFX (environment_root.gd). Имена Bake*: прогон переключает bake_mode по ним
func _add_lights(root: Node3D) -> void:
	var lamp := SpotLight3D.new()
	lamp.name = "BakeLamp"
	lamp.position = Vector3(0.0, 120.0, 0.0)
	lamp.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	lamp.light_color = Color(1.0, 0.82, 0.6)
	lamp.light_energy = 200.0
	lamp.spot_range = 700.0
	lamp.spot_angle = 65.0
	lamp.shadow_enabled = true
	lamp.shadow_bias = 0.6
	lamp.shadow_normal_bias = 3.0
	lamp.light_size = 15.0
	lamp.light_bake_mode = Light3D.BAKE_STATIC
	root.add_child(lamp)
	var moon := DirectionalLight3D.new()
	moon.name = "BakeMoon"
	moon.rotation_degrees = Vector3(-35.0, 180.0, 0.0)   # луч идёт от окна (север, -Z) в комнату и вниз
	moon.light_color = Color(0.55, 0.65, 1.0)
	moon.light_energy = 0.12
	moon.shadow_enabled = true
	moon.light_bake_mode = Light3D.BAKE_STATIC
	root.add_child(moon)


func _add_lightmap_gi(root: Node3D) -> void:
	var gi := LightmapGI.new()
	gi.name = "LightmapGI"
	gi.directional = true            # 4.8: направленный lightmap запекает и specular (блик пластика на мебели)
	gi.quality = LightmapGI.BAKE_QUALITY_MEDIUM
	gi.bounces = 3
	gi.use_denoiser = true
	gi.interior = true
	gi.max_texture_size = 8192
	gi.generate_probes_subdiv = LightmapGI.GENERATE_PROBES_SUBDIV_8
	gi.environment_mode = LightmapGI.ENVIRONMENT_MODE_CUSTOM_COLOR
	gi.environment_custom_color = Color(0.03, 0.05, 0.12)
	gi.environment_custom_energy = 1.0
	root.add_child(gi)


func _set_owner(n: Node, o: Node) -> void:
	for c in n.get_children():
		c.owner = o
		_set_owner(c, o)
