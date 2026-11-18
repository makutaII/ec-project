class_name LookLab extends Node

########################
## Look Lab (debug): прогон вариантов картинки одним заходом (ATTN_14 §14.13).
########################
## Кнопка на вкладке Keys панели F3 (или Ctrl+Shift+L): для каждого варианта из _variants() применяет его поверх Look `clean` + Time `day`,
## переезжает по закладкам камеры 1-5 (Settings camera/bookmarks; нет закладок: снимает текущий вид),
## снимает кадр без UI на выбранном качестве (High по умолчанию) и пишет в user://look_lab/<время>/:
##   <вариант>_b<N>.jpg, metrics.csv, variants.txt (параметры прогона).
## metrics.csv: насыщенность, яркость, разброс яркости, доля насыщенных пикселей (те же формулы, что в анализе
## скриншотов Golf 2), плюс draw calls, объекты, примитивы, время кадра GPU и CPU, fps (Performance, §14.7.1).
## После прогона всё возвращается: Look, Time, Quality, Environment, камера, UI.
## Запускать в режиме Observe (виньетка и tilt-shift работают только там). Во время прогона мышь и клавиши не трогать.
## Вариант (_variants): {"id": "...", "look": {поле GraphicsPreset: значение}, "time": {поле TimeOfDayPreset: значение},
##           "env": {свойство Environment: значение}}. Все поля необязательны.
## Кнопки на вкладке Keys панели F3: прогон на High, Medium, Low (в папке user://look_lab/<время>_<tier>/).

## Снимки пишутся в JPEG (около 0,3 МБ вместо 1,5 МБ у PNG); метрики считаются по изображению до сжатия
const JPEG_QUALITY := 0.9
const OUT_DIR := "user://look_lab/"
const BASE_LOOK := &"clean"
const BASE_TIME := &"day"
const SETTLE_FIRST := 30   # кадров после смены варианта (тени, volumetric fog сходятся не сразу)
const SETTLE_VIEW := 12    # кадров после смены закладки

const _WARM := Color(1.0, 0.90, 0.74)
const _COOL := Color(0.62, 0.70, 0.86)
## Варианты прогона. База = текущие Clean + Day из .tres/.gd, без переопределений. Сейчас проверяется заполняющий свет
## SkyFill (второй directional без стен и потолка): энергия (Time.fill_energy × Look.fill_mul), мягкость (Look.fill_angle, град),
## ambient под него. Хотим: мягкие тени предметов вне пятна окна, объём без плоского ambient.
func _variants() -> Array:
	return [
		_mk("r7_0_base", {}),
		_mk("r7_1_off", {"fill_mul": 0.0}),
		_mk("r7_2_half", {"fill_mul": 0.5}),
		_mk("r7_3_x15", {"fill_mul": 1.5}),
		_mk("r7_4_x15_amb50", {"fill_mul": 1.5, "ambient_energy": 0.5}),
		_mk("r7_5_x15_amb35", {"fill_mul": 1.5, "ambient_energy": 0.35}),
		_mk("r7_6_x15_amb50_ang2", {"fill_mul": 1.5, "ambient_energy": 0.5, "fill_angle": 2.0}),
		_mk("r7_7_x15_amb50_ang14", {"fill_mul": 1.5, "ambient_energy": 0.5, "fill_angle": 14.0}),
		_mk("r7_8_x15_amb50_el45", {"fill_mul": 1.5, "ambient_energy": 0.5}, {"fill_elevation": 45.0}),
		_mk("r7_9_x20_amb35_c115", {"fill_mul": 2.0, "ambient_energy": 0.35, "contrast": 1.15}),
	]


func _mk(id: String, look: Dictionary, time := {}, env := {}) -> Dictionary:
	return {"id": id, "look": look, "time": time, "env": env}


func _m(a: Dictionary, b: Dictionary) -> Dictionary:
	var r := a.duplicate()
	r.merge(b, true)
	return r


func _t(time: Dictionary, elevation: float) -> Dictionary:
	return _m(time, {"sun_elevation": elevation})


func _fog(density: float) -> Dictionary:
	return {"volumetric_fog_enabled": true, "volumetric_fog_density": density, "volumetric_fog_length": 600.0,
			"volumetric_fog_albedo": Color(1.0, 0.96, 0.88), "volumetric_fog_anisotropy": 0.6}


## Действия InputMap: [клавиша по physical_keycode, tier качества]. Кнопки «Нажать» на вкладке Keys панели F3 шлют их же
const ACTIONS := {
	&"debug_look_lab": [KEY_L, &"high"],
	&"debug_look_lab_medium": [KEY_M, &"medium"],
	&"debug_look_lab_low": [KEY_K, &"low"],
}
## Матрица Look × Time (все пресеты, текущая настройка, без вариантов): [клавиша, tier]
const MATRIX_ACTIONS := {
	&"debug_look_matrix": [KEY_N, &"high"],
	&"debug_look_matrix_medium": [KEY_B, &"medium"],
	&"debug_look_matrix_low": [KEY_J, &"low"],
}

var _busy := false


func _ready() -> void:
	var all := ACTIONS.duplicate()
	all.merge(MATRIX_ACTIONS)
	for a in all:
		if InputMap.has_action(a):
			continue
		InputMap.add_action(a)
		var ev := InputEventKey.new()
		ev.physical_keycode = all[a][0]
		ev.ctrl_pressed = true
		ev.shift_pressed = true
		InputMap.action_add_event(a, ev)
	print("[LookLab] готов: кнопки «Нажать» на вкладке Keys панели F3 (High, Medium, Low) или Ctrl+Shift+L / M / K")


func _unhandled_input(event: InputEvent) -> void:
	if not Global.debug_mode:
		return
	for a in ACTIONS:
		if event.is_action_pressed(a) and not event.is_echo():
			get_viewport().set_input_as_handled()
			print("[LookLab] запуск, качество ", ACTIONS[a][1])
			run([], ACTIONS[a][1])
			return
	for a in MATRIX_ACTIONS:
		if event.is_action_pressed(a) and not event.is_echo():
			get_viewport().set_input_as_handled()
			print("[LookLab] матрица Look × Time, качество ", MATRIX_ACTIONS[a][1])
			run_matrix(MATRIX_ACTIONS[a][1])
			return


## Прогон. only: id вариантов (пусто = все), quality: tier качества на время прогона
func run(only: Array = [], quality: StringName = &"high") -> void:
	if _busy:
		return
	var gimbal := get_node_or_null("/root/GameRoot/Gimbal") as Gimbal
	var env: Environment = GFX.get("_env")
	if gimbal == null or env == null or not GFX.looks.has(BASE_LOOK) or not GFX.times.has(BASE_TIME):
		push_warning("LookLab: нет Gimbal, Environment или пресетов %s / %s (режим --fast?)" % [BASE_LOOK, BASE_TIME])
		return
	_busy = true

	var ui := get_node_or_null("/root/GameRoot/UI")
	var views := _views(gimbal)
	var prev := {"look": GFX.state.look, "time": GFX.state.time, "quality": GFX.state.quality}
	var look0: GraphicsPreset = GFX.looks[BASE_LOOK]
	var time0: TimeOfDayPreset = GFX.times[BASE_TIME]
	var view0 := gimbal.get_view()
	var ui_was := true
	if ui and ui.has_method("is_hud_visible"):
		ui_was = ui.is_hud_visible()
		ui.set_hud_visible(false)
	elif ui and "visible" in ui:
		ui_was = ui.visible
		ui.visible = false
	Hints.suspend(true)
	if not bool(GFX.get("_observe_active")):
		print("[LookLab] ВНИМАНИЕ: не режим Observe, виньетка и tilt-shift в кадрах не появятся")

	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var dir := OUT_DIR + stamp + "_" + String(quality) + "/"
	DirAccess.make_dir_recursive_absolute(dir)
	var rows: Array[String] = ["variant,view,sat,val,val_std,sat50_pct,draw_calls,objects,primitives,gpu_ms,cpu_ms,fps"]
	var variants := _variants()
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var vsync_was := DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)   # без V-Sync fps и время кадра честные
	var env_saved := {}
	var done := 0

	GFX.apply_quality(quality, 0.0, false)
	for v in variants:
		var id: String = v.id
		if not only.is_empty() and not only.has(id):
			continue
		_restore_env(env, env_saved)
		var look := look0.duplicate() as GraphicsPreset
		_set_props(look, v.get("look", {}), id)
		var tod := time0.duplicate() as TimeOfDayPreset
		_set_props(tod, v.get("time", {}), id)
		GFX.looks[BASE_LOOK] = look
		GFX.times[BASE_TIME] = tod
		GFX.apply_look(BASE_LOOK, 0.0)
		GFX.apply_time(BASE_TIME, 0.0)
		var extra: Dictionary = v.get("env", {})
		for k in extra:
			if not (k in env):
				push_warning("LookLab[%s]: у Environment нет свойства '%s'" % [id, k])
				continue
			if not env_saved.has(k):
				env_saved[k] = env.get(k)
			env.set(k, extra[k])
		await _frames(SETTLE_FIRST)

		for i in views.size():
			var vw: Dictionary = views[i].view
			gimbal.set_view(vw.pivot, vw.yaw, vw.pitch, vw.dist, true)
			await _frames(SETTLE_VIEW)
			var tm := await _measure(vp)
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var shot := "%s_%s" % [id, views[i].name]
			var err := img.save_jpg(dir + shot + ".jpg", JPEG_QUALITY)
			if err != OK:
				push_error("LookLab: не сохранён %s (код %d)" % [shot, err])
			var s := _stats(img)
			rows.append("%s,%s,%.3f,%.3f,%.3f,%.1f,%d,%d,%d,%.2f,%.2f,%.0f" % [id, views[i].name, s.sat, s.val, s.val_std, s.sat50,
					int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
					int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
					int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)), tm.gpu, tm.cpu, tm.fps])
		done += 1
		print("[LookLab] %s готов (%d/%d)" % [id, done, variants.size() if only.is_empty() else only.size()])

	# --- Возврат состояния ---
	_restore_env(env, env_saved)
	RenderingServer.viewport_set_measure_render_time(vp, false)
	DisplayServer.window_set_vsync_mode(vsync_was)
	GFX.looks[BASE_LOOK] = look0
	GFX.times[BASE_TIME] = time0
	GFX.apply_look(prev.look, 0.0)
	GFX.apply_time(prev.time, 0.0)
	GFX.apply_quality(prev.quality, 0.0, false)
	gimbal.set_view(view0.pivot, view0.yaw, view0.pitch, view0.dist, true)
	if ui and ui.has_method("set_hud_visible"):
		ui.set_hud_visible(ui_was)
	elif ui and "visible" in ui:
		ui.visible = ui_was
	Hints.suspend(false)

	_write(dir + "metrics.csv", "\n".join(rows) + "\n")
	_write(dir + "variants.txt", var_to_str(variants))
	print("[LookLab] готово, файлы: ", ProjectSettings.globalize_path(dir))
	_busy = false


## Матрица: каждый Look × каждый Time на текущих настройках (без вариантов), по закладкам камеры.
## Снимки <look>_<time>_b<N>.jpg и metrics.csv (look,time,view,...) в user://look_lab/<время>_matrix_<tier>/. Нужна для L4:
## как выглядят и сколько стоят остальные пресеты после правок Clean + Day.
func run_matrix(quality: StringName = &"high") -> void:
	if _busy:
		return
	var gimbal := get_node_or_null("/root/GameRoot/Gimbal") as Gimbal
	if gimbal == null or GFX.get("_env") == null:
		push_warning("LookLab: нет Gimbal или Environment (режим --fast?)")
		return
	_busy = true
	var ui := get_node_or_null("/root/GameRoot/UI")
	var views := _views(gimbal)
	var prev := {"look": GFX.state.look, "time": GFX.state.time, "quality": GFX.state.quality}
	var view0 := gimbal.get_view()
	var ui_was := true
	if ui and ui.has_method("is_hud_visible"):
		ui_was = ui.is_hud_visible()
		ui.set_hud_visible(false)
	elif ui and "visible" in ui:
		ui_was = ui.visible
		ui.visible = false
	Hints.suspend(true)
	var observe_was := bool(GFX.get("_observe_active"))
	GFX.set("_observe_active", true)
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var vsync_was := DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var dir := OUT_DIR + Time.get_datetime_string_from_system().replace(":", "-") + "_matrix_" + String(quality) + "/"
	DirAccess.make_dir_recursive_absolute(dir)
	var rows: Array[String] = ["look,time,view,sat,val,val_std,sat50_pct,draw_calls,objects,primitives,gpu_ms,cpu_ms,fps"]
	GFX.apply_quality(quality, 0.0, false)
	var looks: Array = GFX.looks.keys()
	var times: Array = GFX.times.keys()
	looks.sort()
	times.sort()
	var n := 0
	for l in looks:
		for t in times:
			GFX.apply_look(l, 0.0)
			GFX.apply_time(t, 0.0)
			await _frames(SETTLE_FIRST)
			for i in views.size():
				var vw: Dictionary = views[i].view
				gimbal.set_view(vw.pivot, vw.yaw, vw.pitch, vw.dist, true)
				await _frames(SETTLE_VIEW)
				var tm := await _measure(vp)
				await RenderingServer.frame_post_draw
				var img := get_viewport().get_texture().get_image()
				var shot := "%s_%s_%s" % [l, t, views[i].name]
				if img.save_jpg(dir + shot + ".jpg", JPEG_QUALITY) != OK:
					push_error("LookLab: не сохранён " + shot)
				var st := _stats(img)
				rows.append("%s,%s,%s,%.3f,%.3f,%.3f,%.1f,%d,%d,%d,%.2f,%.2f,%.0f" % [l, t, views[i].name, st.sat, st.val, st.val_std, st.sat50,
						int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
						int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
						int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)), tm.gpu, tm.cpu, tm.fps])
			n += 1
			print("[LookLab] %s + %s готов (%d/%d)" % [l, t, n, looks.size() * times.size()])
	RenderingServer.viewport_set_measure_render_time(vp, false)
	DisplayServer.window_set_vsync_mode(vsync_was)
	GFX.set("_observe_active", observe_was)
	GFX.apply_look(prev.look, 0.0)
	GFX.apply_time(prev.time, 0.0)
	GFX.apply_quality(prev.quality, 0.0, false)
	gimbal.set_view(view0.pivot, view0.yaw, view0.pitch, view0.dist, true)
	if ui and ui.has_method("set_hud_visible"):
		ui.set_hud_visible(ui_was)
	elif ui and "visible" in ui:
		ui.visible = ui_was
	Hints.suspend(false)
	_write(dir + "metrics.csv", "\n".join(rows) + "\n")
	print("[LookLab] матрица готова, файлы: ", ProjectSettings.globalize_path(dir))
	_busy = false


# ==========================================
# Вспомогательное
# ==========================================

func _views(gimbal: Gimbal) -> Array:
	var res: Array = []
	var stored = Settings.get_value("camera", "bookmarks", [])
	if stored is Array:
		for i in stored.size():
			var bm = stored[i]
			if bm is Dictionary and bm.has("pivot") and bm.has("yaw") and bm.has("pitch") and bm.has("dist"):
				res.append({"name": "b%d" % (i + 1), "view": bm})
	if res.is_empty():
		res.append({"name": "cur", "view": gimbal.get_view()})
		print("[LookLab] закладок нет (клавиши 1-5 в Observe их сохраняют), снимаю текущий вид")
	return res


func _set_props(obj: Object, props: Dictionary, variant_id: String) -> void:
	for k in props:
		if not (k in obj):
			push_warning("LookLab[%s]: у %s нет поля '%s'" % [variant_id, obj.get_class(), k])
			continue
		obj.set(k, props[k])


func _restore_env(env: Environment, saved: Dictionary) -> void:
	for k in saved:
		env.set(k, saved[k])
	saved.clear()


## Среднее время кадра GPU и CPU (мс) за несколько кадров и fps. Без V-Sync числа точнее
func _measure(vp: RID, frames := 6) -> Dictionary:
	var gpu := 0.0
	var cpu := 0.0
	for i in frames:
		await get_tree().process_frame
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
	return {"gpu": gpu / frames, "cpu": cpu / frames, "fps": Engine.get_frames_per_second()}


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Те же формулы, что в анализе скриншотов: S = (max-min)/max, V = max (по sRGB-значениям картинки)
func _stats(img: Image) -> Dictionary:
	var s := img.duplicate() as Image
	s.convert(Image.FORMAT_RGB8)
	s.resize(240, 135, Image.INTERPOLATE_BILINEAR)
	var w := s.get_width()
	var h := s.get_height()
	var sum_s := 0.0
	var sum_v := 0.0
	var sum_v2 := 0.0
	var hi := 0
	for y in h:
		for x in w:
			var c := s.get_pixel(x, y)
			var mx := maxf(c.r, maxf(c.g, c.b))
			var mn := minf(c.r, minf(c.g, c.b))
			var sat := 0.0 if mx <= 0.0 else (mx - mn) / mx
			sum_s += sat
			sum_v += mx
			sum_v2 += mx * mx
			if sat > 0.5:
				hi += 1
	var n := float(w * h)
	var mean_v := sum_v / n
	return {
		"sat": sum_s / n,
		"val": mean_v,
		"val_std": sqrt(maxf(sum_v2 / n - mean_v * mean_v, 0.0)),
		"sat50": 100.0 * hi / n,
	}


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("LookLab: не записан " + path)
		return
	f.store_string(text)
