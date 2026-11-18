extends Node3D

## ATTN_14 D2: прогон пробного bake. Динамический свет (лампа и луна как обычные тени) против запечённого lightmap.
## Подготовка: tests/bake/room_bake_prep.gd (File, Run) и «Bake Lightmaps» на узле LightmapGI в tests/bake/out/room_bake_trial.scn.
## Запуск: F6 на tests/bake/room_bake_run.tscn. В Output печатается таблица, кадры лежат в user://bake_trial/ (dynamic.png, baked.png).
## Цифры GPU и fps снимаются на вашем железе: то же самое повторите при качестве Low и High (в этой сцене только свет и комната, без GFX).
## Решение по D2 (брать ли bake в игру) принимаем по таблице: ATTN_14 D2.

const SCENE := "res://tests/bake/out/room_bake_trial.scn"
const OUT_DIR := "res://tests/bake/out"
const SHOT_DIR := "user://bake_trial/"
const WARMUP := 45
const SAMPLES := 240

var _room: Node3D
var _gi: LightmapGI
var _lights: Array[Light3D] = []
var _label: Label


func _ready() -> void:
	_setup_view()
	_say("D2: пробный bake света. Подготовка…")
	if not ResourceLoader.exists(SCENE):
		_fail("Нет %s. Запустите tests/bake/room_bake_prep.gd (File, Run)." % SCENE)
		return
	_room = (load(SCENE) as PackedScene).instantiate() as Node3D
	add_child(_room)
	_gi = _room.get_node_or_null("LightmapGI") as LightmapGI
	if _gi == null:
		_fail("В сцене нет узла LightmapGI: пересоздайте её через room_bake_prep.gd.")
		return
	if _gi.light_data == null:
		# bake записал .lmbake, но сцену после bake не сохранили: ссылка на данные не попала в .scn
		for f in DirAccess.get_files_at(OUT_DIR):
			if f.get_extension() == "lmbake":
				_gi.light_data = load(OUT_DIR + "/" + f) as LightmapGIData
				print("[BakeRun] данные lightmap подхвачены из %s (сцену после bake лучше сохранить: Ctrl+S)" % f)
				break
	if _gi.light_data == null:
		_fail("Lightmap не запечён или сцена не сохранена после bake. Откройте tests/bake/out/room_bake_trial.scn, выберите LightmapGI, Bake Lightmaps, затем Ctrl+S, и снова F6.")
		return
	for n in _room.find_children("Bake*", "Light3D", false, false):
		_lights.append(n as Light3D)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	await _run_all()
	_say("Готово. Таблица в Output, кадры: %s. Окно можно закрыть." % ProjectSettings.globalize_path(SHOT_DIR))


## Сообщение в Output и на экране (окно остаётся открытым, чтобы его было видно)
func _say(text: String) -> void:
	print("[BakeRun] " + text)
	if _label == null:
		var layer := CanvasLayer.new()
		layer.layer = 10
		add_child(layer)
		_label = Label.new()
		_label.position = Vector2(16.0, 16.0)
		_label.add_theme_font_size_override("font_size", 20)
		layer.add_child(_label)
	_label.text = text


func _fail(text: String) -> void:
	push_warning("[BakeRun] " + text)
	_say(text)


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


## baked: так будет в игре с bake: lightmap включён, лампа и луна выключены (свет уже в текстурах).
## dynamic: lightmap выключен, лампа и луна как обычные динамические источники с тенями.
## Прежняя версия оставляла источники включёнными (BAKE_STATIC), поэтому они продолжали считаться в реальном времени
func _set_baked(baked: bool) -> void:
	_gi.visible = baked
	for l in _lights:
		l.visible = not baked
		l.light_bake_mode = Light3D.BAKE_STATIC if baked else Light3D.BAKE_DISABLED


## Один замер: режим и масштаб 3D-рендера (2.0 даёт 4x пикселей: так разница по GPU видна и на сильной видеокарте).
## fps считается по времени кадров, а не по Engine.get_frames_per_second (тот обновляется раз в секунду и после загрузки показывает 1)
func _measure(vp: RID, baked: bool, scale: float) -> Dictionary:
	get_viewport().scaling_3d_scale = scale
	_set_baked(baked)
	for i in WARMUP:
		await get_tree().process_frame
	var tex := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	var cpu := 0.0
	var gpu := 0.0
	var t0 := Time.get_ticks_usec()
	for i in SAMPLES:
		await get_tree().process_frame
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
	var secs := (Time.get_ticks_usec() - t0) / 1000000.0
	return {"fps": SAMPLES / secs, "gpu": gpu / SAMPLES, "cpu": cpu / SAMPLES, "tex": tex / 1048576.0}


func _run_all() -> void:
	var vp := get_viewport().get_viewport_rid()
	var vsync_was := DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(vp, true)
	print("== D2: пробный bake света (прогрев %d кадров, %d замеров, режимы по кругу, считается второй круг)" % [WARMUP, SAMPLES])
	print("lightmap: %s" % [_gi.light_data.resource_path if _gi.light_data.resource_path != "" else "встроен в сцену"])
	# Первый круг: шейдеры, загрузка текстур и теней проходят до замеров, иначе первый режим выглядит хуже
	for i in 120:
		await get_tree().process_frame
	var rows := []
	for scale in [1.0, 2.0]:
		for pass_i in 2:
			for baked in [false, true]:
				var r := await _measure(vp, baked, scale)
				if pass_i == 1:
					r["mode"] = "baked" if baked else "dynamic"
					r["scale"] = scale
					rows.append(r)
					if scale == 1.0:
						await RenderingServer.frame_post_draw
						get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path(SHOT_DIR + r.mode + ".png"))
	get_viewport().scaling_3d_scale = 1.0
	RenderingServer.viewport_set_measure_render_time(vp, false)
	DisplayServer.window_set_vsync_mode(vsync_was)
	print("%-8s %6s %8s %9s %9s %10s" % ["режим", "3D", "fps", "GPU, мс", "CPU, мс", "текст., МБ"])
	for r in rows:
		print("%-8s %6.1f %8.1f %9.3f %9.3f %10.1f" % [r.mode, r.scale, r.fps, r.gpu, r.cpu, r.tex])
	for i in range(0, rows.size(), 2):
		var d: Dictionary = rows[i]
		var b: Dictionary = rows[i + 1]
		print("3D x%.1f: baked против dynamic: GPU %+.1f%%, fps %+.1f%%, текстуры %+.1f МБ" % [d.scale, (b.gpu / maxf(d.gpu, 0.001) - 1.0) * 100.0, (b.fps / maxf(d.fps, 0.001) - 1.0) * 100.0, b.tex - d.tex])
	print("кадры: %s" % ProjectSettings.globalize_path(SHOT_DIR))
