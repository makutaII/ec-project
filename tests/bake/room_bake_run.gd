extends Node3D

## ATTN_14 D2: прогон пробного bake. Динамический свет (лампа и луна как обычные тени) против запечённого lightmap.
## Подготовка: tests/bake/room_bake_prep.gd (File, Run) и «Bake Lightmaps» на узле LightmapGI в tests/bake/out/room_bake_trial.scn.
## Запуск: F6 на tests/bake/room_bake_run.tscn. В Output печатается таблица, кадры лежат в user://bake_trial/ (dynamic.png, baked.png).
## Цифры GPU и fps снимаются на вашем железе: то же самое повторите при качестве Low и High (в этой сцене только свет и комната, без GFX).
## Решение по D2 (брать ли bake в игру) принимаем по таблице: ATTN_14 D2.

const SCENE := "res://tests/bake/out/room_bake_trial.scn"
const SHOT_DIR := "user://bake_trial/"
const WARMUP := 45
const SAMPLES := 240

var _room: Node3D
var _gi: LightmapGI
var _lights: Array[Light3D] = []


func _ready() -> void:
	if not ResourceLoader.exists(SCENE):
		print("[BakeRun] нет %s: запустите tests/bake/room_bake_prep.gd" % SCENE)
		get_tree().quit()
		return
	_room = (load(SCENE) as PackedScene).instantiate() as Node3D
	add_child(_room)
	_gi = _room.get_node_or_null("LightmapGI") as LightmapGI
	for n in _room.find_children("Bake*", "Light3D", false, false):
		_lights.append(n as Light3D)
	if _gi == null or _gi.light_data == null:
		print("[BakeRun] lightmap не запечён: откройте сцену из tests/bake/out/, выберите LightmapGI и нажмите «Bake Lightmaps», затем снова F6")
		get_tree().quit()
		return
	_setup_view()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	await _run_all()
	get_tree().quit()


func _setup_view() -> void:
	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.position = Vector3(0.0, 90.0, 230.0)
	add_child(cam)
	cam.look_at(Vector3(0.0, -10.0, 0.0))
	cam.current = true
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.05, 0.12)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.03, 0.05, 0.12)
	env.ambient_light_energy = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _set_baked(baked: bool) -> void:
	_gi.visible = baked
	for l in _lights:
		l.light_bake_mode = Light3D.BAKE_STATIC if baked else Light3D.BAKE_DYNAMIC


func _run_all() -> void:
	var vp := get_viewport().get_viewport_rid()
	var vsync_was := DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(vp, true)
	print("== D2: пробный bake света (%d кадров прогрева, %d замеров)" % [WARMUP, SAMPLES])
	print("lightmap: %s" % [_gi.light_data.resource_path if _gi.light_data.resource_path != "" else "встроен в сцену"])
	var rows := []
	for baked in [false, true]:
		var tex0 := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
		_set_baked(baked)
		for i in WARMUP:
			await get_tree().process_frame
		var cpu := 0.0
		var gpu := 0.0
		var fps := 0.0
		for i in SAMPLES:
			await get_tree().process_frame
			cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
			gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
			fps += Engine.get_frames_per_second()
		var mode := "baked" if baked else "dynamic"
		var tex_mb := (Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) - tex0) / 1048576.0
		rows.append({"mode": mode, "fps": fps / SAMPLES, "gpu": gpu / SAMPLES, "cpu": cpu / SAMPLES, "tex": tex_mb})
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path(SHOT_DIR + mode + ".png"))
	RenderingServer.viewport_set_measure_render_time(vp, false)
	DisplayServer.window_set_vsync_mode(vsync_was)
	print("%-9s %8s %9s %9s %12s" % ["режим", "fps", "GPU, мс", "CPU, мс", "текстуры, МБ"])
	for r in rows:
		print("%-9s %8.1f %9.2f %9.2f %12.1f" % [r.mode, r.fps, r.gpu, r.cpu, r.tex])
	var d: Dictionary = rows[0]
	var b: Dictionary = rows[1]
	print("baked против dynamic: GPU %+.1f%%, fps %+.1f%%" % [(b.gpu / maxf(d.gpu, 0.001) - 1.0) * 100.0, (b.fps / maxf(d.fps, 0.001) - 1.0) * 100.0])
	print("кадры: %s" % ProjectSettings.globalize_path(SHOT_DIR))
