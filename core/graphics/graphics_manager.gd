extends Node
# class_name не задаём: это синглтон GFX (autoload)

###########################
##💡 GFX - сервис графики (autoload)
############################
## Три независимые оси: Look (стиль, S3), Time (время суток, S4), Quality (стоимость, S5).
## Итоговая картинка = Look (база) * Time (модификатор). Quality режет дорогое сверху (S5).
## Хранит состояние и применяет его к нодам окружения. Ноды находит по группам:
##   gfx_env (WorldEnvironment), gfx_sun (DirectionalLight3D), gfx_lamp (SpotLight3D),
##   gfx_probe (ReflectionProbe), gfx_sky (небо в окне, создает RoomBuilder).
## Их создает EnvironmentRoot, либо вы сами добавляете свои ноды в эти группы.
##
## Карточки Observe (категории look и light) приходят сигналом ObserveController.observe_action.
## Числовые параметры меняются плавным твином, дискретные (вкл/выкл эффектов) переключаются на краях перехода.

signal look_changed(id: StringName)
## ⚡Здания и фары подписываются на него, чтобы включаться ночью
signal time_of_day_changed(id: StringName)
## ⚡Контуры, tilt-shift и комната (LOD) подстраиваются под tier
signal quality_changed(id: StringName)
## Тени траков включили или выключили (или сменился tier, от которого зависит умолчание)
signal track_shadows_changed(on: bool)
signal lamp_changed(on: bool)
## Lab (корректор графики, ATTN_14 §14.16) включён или выключен
signal lab_changed(on: bool)

const LOOKS_DIR := "res://data/graphics/looks/"
const TIMES_DIR := "res://data/graphics/time/"
const QUALITY_DIR := "res://data/graphics/quality/"
## Настройки игрока (не сейв): tier качества и последние Look и Time
const DEFAULT_LOOK := &"toy"
const DEFAULT_TIME := &"day"
const DEFAULT_TRANSITION := 0.5

var state := {"look": DEFAULT_LOOK, "time": DEFAULT_TIME, "quality": &"medium"}
## Тени траков: -1 как в пресете качества, 0 выкл, 1 вкл (выбор игрока, пишется в settings.cfg)
var _track_shadows_override := -1
## id -> GraphicsPreset
var looks := {}
## id -> TimeOfDayPreset
var times := {}
## id -> QualityPreset
var qualities := {}

## Бюджет источников света сущностей (ATTN_16 §16.6). Создаётся в _ready, регистрируются C_Mechanisms
var light_budget: LightBudget
## Оверлей статистики в углу (fps, draw calls, треугольники, траки и вагоны). Только отладочная сборка, F4
var stats: StatsOverlay

## Корректор графики (только debug, в --fast его нет). Пока lab_mode включён, Look, Time и Quality не применяются
var lab: GfxLab
var lab_mode := false

var _world_env: WorldEnvironment
var _env: Environment
var _sun: DirectionalLight3D
var _lamp: SpotLight3D
var _fill: DirectionalLight3D   # заполняющий свет «небо» (EnvironmentRoot._ensure_sky_fill)
var _probe: ReflectionProbe
var _sky: MeshInstance3D
var _oc: Node   # ObserveController
var _sun_base_energy := 1.0
var _sun_off_by_room := false   # Sun скрыт комнатой без дневного света (вернуть при смене комнаты)

## Ручной переключатель лампы: -1 авто (Look / Time), 0 выкл, 1 вкл. Сбрасывается при смене Look или Time
var _lamp_override := -1
var _lamp_is_on := false

var _p_ao_multibounce: StringName = &""
var _p_contact_env: StringName = &""
var _p_contact_sun: StringName = &""

var _tween: Tween

# --- Миниатюра (S8) ---
var _mini_layer: CanvasLayer
var _mini_rect: ColorRect
var _mini_mat: ShaderMaterial
var _cam_attr: CameraAttributesPractical
var _observe_active := false   # tilt-shift, DOF и виньетка работают только в Observe
var _dof_on := false

## Tilt-shift и виньетка одним полноэкранным проходом по картинке 3D (CanvasLayer -2: под контурами и UI).
## Размытие через mip-уровни экрана, поэтому дёшево. pitch_scale ослабляет эффект при взгляде не сверху
const MINI_SHADER := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform float strength : hint_range(0.0, 1.0) = 0.0;
uniform float pitch_scale : hint_range(0.0, 1.0) = 1.0;
uniform float focus_y : hint_range(0.0, 1.0) = 0.55;
uniform float band : hint_range(0.0, 0.5) = 0.16;
uniform float falloff : hint_range(0.01, 0.8) = 0.32;
uniform float max_lod = 3.5;
uniform float vignette : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 uv = SCREEN_UV;
	float d = max(abs(uv.y - focus_y) - band, 0.0);
	float m = smoothstep(0.0, falloff, d) * strength * pitch_scale;
	float lod = m * max_lod;
	vec3 c = textureLod(screen_tex, uv, lod).rgb;
	if (lod > 0.25) {
		float rad = lod * 1.3;
		vec3 acc = c;
		for (int i = 0; i < 8; i++) {
			float a = float(i) * 0.785398;
			acc += textureLod(screen_tex, uv + vec2(cos(a), sin(a)) * rad * SCREEN_PIXEL_SIZE, lod).rgb;
		}
		c = acc / 9.0;
	}
	vec2 q = (uv - vec2(0.5)) * vec2(1.0, 0.85);
	float v = smoothstep(0.35, 0.85, length(q) * 1.25);
	c *= 1.0 - v * vignette;
	COLOR = vec4(c, 1.0);
}
"""


func _ready() -> void:
	set_process(false)
	light_budget = LightBudget.new()
	light_budget.name = "LightBudget"
	add_child(light_budget)
	if Global.debug_mode:
		stats = StatsOverlay.new()
		add_child(stats)
	if Global.fast_debug:
		# Режим быстрой загрузки: без пресетов Look и Time, без миниатюры, только Low и без SDFGI
		_load_presets()
		_load_settings()
		await get_tree().process_frame
		if _resolve():
			_apply_fast()
		_debug_perf()
		return
	_build_miniature()
	_load_presets()
	_load_settings()
	if Global.debug_mode:
		lab = GfxLab.new()
	# EnvironmentRoot, RoomBuilder и ObserveController встают в группы в своих _ready
	await get_tree().process_frame
	if _resolve():
		_discover_features()
		_apply_quality_settings()
		_apply_all(0.0)
	_connect_observe()
	_debug_perf()
	if Global.debug_mode:
		# add_child(LookLab.new())   # Ctrl+Shift+L: прогон вариантов картинки (ATTN_14 §14.13)
		pass

func _unhandled_input(event: InputEvent) -> void:
	# Ctrl+Shift+V (действие debug_vsync_toggle, debug): V-Sync вкл/выкл. По умолчанию V-Sync включён, поэтому fps
	# упирается в частоту монитора. Раньше был F8, но в редакторе Godot это «Остановить игру»
	if Global.debug_mode and InputMap.has_action(&"debug_vsync_toggle") \
			and event.is_action_pressed(&"debug_vsync_toggle") and not event.is_echo():
		_toggle_vsync()
	# F4 (debug): оверлей статистики
	if Global.debug_mode and Actions.pressed(event, &"debug_stats_toggle"):
		set_stats_shown(not is_stats_shown())
	# F10 (debug): сохранить встроенные Look и Time в .tres для правки
	if Global.debug_mode and Actions.pressed(event, &"debug_save_look"):
		save_builtin_presets()


# ==========================================
# ПУБЛИЧНЫЙ API
# ==========================================

## Применить Look. duration = 0: мгновенно
func apply_look(id: StringName, duration := DEFAULT_TRANSITION) -> void:
	if not looks.has(id):
		push_warning("GFX: нет пресета Look '%s'" % id)
		return
	exit_lab()
	state.look = id
	_lamp_override = -1
	_apply_all(duration)
	_save_settings()
	look_changed.emit(id)


## Применить время суток
func apply_time(id: StringName, duration := DEFAULT_TRANSITION) -> void:
	if not times.has(id):
		push_warning("GFX: нет пресета Time '%s'" % id)
		return
	exit_lab()
	state.time = id
	_lamp_override = -1
	_apply_all(duration)
	_save_settings()
	time_of_day_changed.emit(id)


## Применить уровень качества (low / medium / high)
## persist = false: временно (фоторежим), в settings.cfg не пишется
func apply_quality(id: StringName, duration := 0.3, persist := true) -> void:
	if not qualities.has(id):
		push_warning("GFX: нет пресета Quality '%s'" % id)
		return
	if lab_mode:
		if not persist:
			return   # временное качество фоторежима в Lab не меняет картинку: снимок делается как есть
		exit_lab()
	state.quality = id
	_apply_quality_settings()
	_apply_all(duration)
	if persist:
		_save_settings()
	quality_changed.emit(id)
	track_shadows_changed.emit(is_track_shadows())


## Пересчитать картинку из текущих значений пресетов (правка на лету: вкладка Graphics панели F3).
## quality_too: заново применить настройки Quality (MSAA, атласы теней, SSAO) и сообщить подписчикам quality_changed
func reapply(quality_too := false) -> void:
	if lab_mode:
		return   # вкладка Graphics правит пресеты, а Lab их не применяет
	if quality_too:
		_apply_quality_settings()
	_apply_all(0.0)
	if quality_too:
		quality_changed.emit(state.quality)


## Тени от траков: выбор игрока, иначе значение пресета качества (по умолчанию выключены)
func is_track_shadows() -> bool:
	if _track_shadows_override >= 0:
		return _track_shadows_override == 1
	var q := get_quality()
	return q != null and q.track_shadows


func set_track_shadows(on: bool, persist := true) -> void:
	_track_shadows_override = 1 if on else 0
	if persist:
		_save_settings()
	track_shadows_changed.emit(on)


func get_quality() -> QualityPreset:
	return qualities.get(state.quality)


func set_stats_shown(on: bool) -> void:
	if stats:
		stats.set_shown(on)


func is_stats_shown() -> bool:
	return stats != null and stats.visible


## Ручное включение лампы над столом
func set_lamp(on: bool, duration := 0.3) -> void:
	if lab_mode:
		lab.set_flag("lamp", on)   # в Lab карточка «Лампа» это птичка лампы
		return
	_lamp_override = 1 if on else 0
	_apply_all(duration)


func is_lamp_on() -> bool:
	return _lamp_is_on


## Режим Observe включён (Lab работает только в нём)
func is_observe_active() -> bool:
	return _observe_active


## Включить Lab: чистый дефолт Godot вместо Look, Time и Quality (ATTN_14 §14.16). Только debug и только в Observe
func enter_lab() -> bool:
	if lab == null or Global.fast_debug:
		return false
	if lab_mode:
		return true
	if not _observe_active:
		push_warning("GFX: Lab включается только в режиме Observe")
		return false
	if _env == null and not _resolve():
		return false
	if _tween:
		_tween.kill()
		_tween = null
	set_process(false)
	lab.enter(_lab_context())
	lab_mode = true
	# Карточки Look, Time и Quality ничего не показывают выбранным: активного пресета нет
	if is_instance_valid(_oc):
		_oc.set_group_state(&"look", &"")
		_oc.set_group_state(&"time", &"")
		_oc.set_group_state(&"quality", &"")
		_oc.set_toggle_state(&"lamp", lab.get_flag("lamp"))
	lab_changed.emit(true)
	return true


## Выключить Lab: Look, Time и Quality применяются заново
func exit_lab() -> void:
	if not lab_mode:
		return
	lab_mode = false
	lab.leave()
	_apply_quality_settings()
	_apply_all(0.0)
	lab_changed.emit(false)


## Всё, что Lab берёт у GFX: ноды, слой миниатюры и тени траков
func _lab_context() -> Dictionary:
	return {
		"world_env": _world_env, "sun": _sun, "sky_fill": _fill, "lamp": _lamp, "probe": _probe,
		"mini_rect": _mini_rect, "mini_mat": _mini_mat, "viewport": get_viewport(),
		"track_get": func() -> int: return _track_shadows_override,
		"track_set": _lab_set_track_shadows,
		"observe_active": func() -> bool: return _observe_active,
	}


func _lab_set_track_shadows(v: int) -> void:
	_track_shadows_override = v
	track_shadows_changed.emit(is_track_shadows())


func get_state() -> Dictionary:
	return state.duplicate()


## Для SavedGame / настроек (S5)
func set_state(d: Dictionary) -> void:
	if lab_mode:
		lab.apply_room_flags()   # комнату сменили, пока Lab включён: пресеты не применяем
		return
	if d.has("look") and looks.has(StringName(d.look)):
		state.look = StringName(d.look)
	if d.has("time") and times.has(StringName(d.time)):
		state.time = StringName(d.time)
	if d.has("quality") and qualities.has(StringName(d.quality)):
		state.quality = StringName(d.quality)
		_apply_quality_settings()
	_lamp_override = -1
	_apply_all(0.0)


## Сохраняет встроенные Look и Time в .tres, существующие файлы не трогает
func save_builtin_presets() -> void:
	_save_builtin(LOOKS_DIR, GraphicsPreset.builtin_ids(), func(id): return GraphicsPreset.builtin(id))
	_save_builtin(TIMES_DIR, TimeOfDayPreset.builtin_ids(), func(id): return TimeOfDayPreset.builtin(id))
	_save_builtin(QUALITY_DIR, QualityPreset.builtin_ids(), func(id): return QualityPreset.builtin(id))


## Диагностика Godot 4.8: печатает всё, что относится к multi-bounce AO и contact shadows.
func dump_props() -> void:
	var kw := ["contact", "bounce", "multi"]
	print("[GFX] --- свойства классов ---")
	for cls in ["Environment", "WorldEnvironment", "Light3D", "DirectionalLight3D", "CameraAttributes",
			"CameraAttributesPractical", "CameraAttributesPhysical", "Camera3D", "Viewport", "SubViewport"]:
		for pr in ClassDB.class_get_property_list(cls, true):
			if _has_kw(String(pr.name), kw):
				print("    ", cls, ".", pr.name, " : ", type_string(pr.type))
	print("[GFX] --- настройки проекта ---")
	for pr in ProjectSettings.get_property_list():
		var n := String(pr.name)
		if n.to_lower().contains("ssao") or _has_kw(n, kw):
			print("    ", n, " = ", ProjectSettings.get_setting(n))
	print("[GFX] --- методы RenderingServer ---")
	for m in ClassDB.class_get_method_list("RenderingServer", true):
		var n := String(m.name)
		if n.to_lower().contains("ssao") or _has_kw(n, kw):
			var args: Array = []
			for a in m.args:
				args.append(String(a.name))
			print("    ", n, "(", ", ".join(args), ")")


# ==========================================
# ПРИМЕНЕНИЕ
# ==========================================

## Собирает итог из state (Look + Time) и применяет его
func _apply_all(duration: float) -> void:
	if lab_mode:
		return
	var look: GraphicsPreset = looks.get(state.look)
	var tod: TimeOfDayPreset = times.get(state.time)
	var q: QualityPreset = qualities.get(state.quality)
	if look == null or tod == null or q == null:
		return
	if _env == null and not _resolve():
		return
	_sky = get_tree().get_first_node_in_group(&"gfx_sky") as MeshInstance3D   # комнату могли пересобрать
	# Свет комнаты: без окон (RoomConfig.daylight = false) солнца и неба нет, ambient свой множитель
	var room := _room_config()
	var daylight := room == null or room.daylight
	var ambient_mul := room.ambient_mul if room else 1.0

	if _tween:
		_tween.kill()
		_tween = null
	if duration > 0.0:
		_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var later: Array[Callable] = []   # что выключаем в конце перехода

	# --- Environment: Look * Time ---
	var e := _env
	e.tonemap_mode = look.tonemap
	e.adjustment_enabled = true
	e.background_mode = Environment.BG_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_flag(e, &"glow_enabled", look.glow_enabled, later)
	_flag(e, &"fog_enabled", look.fog_enabled, later)
	_flag(e, &"ssao_enabled", look.ssao_enabled and q.ssao, later)
	_flag(e, &"ssil_enabled", look.ssil and q.ssil, later)
	_flag(e, &"sdfgi_enabled", q.sdfgi, later)   # в сцене может быть включён: тяжёлый, выключаем по умолчанию
	_to(e, &"tonemap_exposure", look.tonemap_exposure, duration)
	_to(e, &"tonemap_white", look.tonemap_white, duration)
	_to(e, &"adjustment_brightness", look.brightness, duration)
	_to(e, &"adjustment_contrast", look.contrast, duration)
	_to(e, &"adjustment_saturation", look.saturation, duration)
	_to(e, &"glow_intensity", look.glow_intensity, duration)
	_to(e, &"glow_bloom", look.glow_bloom, duration)
	_to(e, &"background_color", look.background_color * tod.background_tint, duration)
	_to(e, &"ambient_light_color", look.ambient_color * tod.ambient_tint, duration)
	_to(e, &"ambient_light_energy", look.ambient_energy * tod.ambient_energy_mul * ambient_mul, duration)
	_to(e, &"fog_light_color", look.fog_color, duration)
	_to(e, &"fog_density", look.fog_density, duration)
	_to(e, &"ssao_radius", look.ssao_radius, duration)
	_to(e, &"ssao_intensity", look.ssao_intensity, duration)
	_to(e, &"ssao_power", look.ssao_power, duration)
	_to(e, &"ssao_light_affect", look.ssao_light_affect, duration)
	_set_feature(e, _p_ao_multibounce, look.ao_multibounce)
	_set_feature(e, _p_contact_env, look.contact_shadows and q.contact_shadows)

	# --- Солнце: Look дает множитель и мягкость, Time дает цвет, угол и энергию ---
	if _sun:
		_sun.shadow_enabled = true   # в сцене по умолчанию выключены
		if not daylight:
			_sun.visible = false   # свет пересчитывать и рисовать тень от выключенного источника незачем
			_sun_off_by_room = true
		elif _sun_off_by_room:
			_sun.visible = true
			_sun_off_by_room = false
		_to(_sun, &"light_color", tod.sun_color, duration)
		_to(_sun, &"light_energy", _sun_base_energy * look.sun_energy_mul * tod.sun_energy * (1.0 if daylight else 0.0), duration)
		_to(_sun, &"shadow_blur", look.sun_shadow_blur, duration)
		_set_feature(_sun, _p_contact_sun, look.contact_shadows and q.contact_shadows)
		_turn_sun(tod, duration)

	# --- Заполняющий свет «небо»: энергия и цвет по Time, множитель и мягкость по Look, тень по Quality ---
	if _fill:
		var fe := tod.fill_energy * look.fill_mul * (1.0 if daylight else 0.0)
		if fe > 0.001:
			_fill.visible = true
		else:
			later.append(func(): _fill.visible = false)
		_fill.shadow_enabled = q.fill_shadow
		_fill.light_angular_distance = look.fill_angle
		var faz := deg_to_rad(tod.sun_azimuth)
		var fel := deg_to_rad(tod.fill_elevation)
		var to_fill := Vector3(sin(faz) * cos(fel), sin(fel), -cos(faz) * cos(fel))
		_fill.global_basis = Basis.looking_at(-to_fill, Vector3.UP)
		_to(_fill, &"light_color", tod.fill_color, duration)
		_to(_fill, &"light_energy", fe, duration)

	# --- Небо в окне ---
	_tint_sky(tod, duration)

	# --- Отражения ---
	if _probe:
		_to(_probe, &"intensity", look.probe_intensity, duration)

	# --- Лампа: авто (Look или Time) или ручной переключатель ---
	var lamp_on := look.lamp_forced_on or tod.lamp_on
	if _lamp_override >= 0:
		lamp_on = _lamp_override == 1
	var lamp_changed_now := lamp_on != _lamp_is_on
	_lamp_is_on = lamp_on
	if _lamp:
		if lamp_on:
			_lamp.visible = true   # включаем сразу, энергия растет твином
		else:
			later.append(func(): _lamp.visible = false)
		_to(_lamp, &"light_energy", look.lamp_energy if lamp_on else 0.0, duration)

	# --- Миниатюра (S8): только в Observe, Quality режет tilt-shift и DOF ---
	var ts := look.tilt_shift if (_observe_active and q.tilt_shift) else 0.0
	var vg := look.vignette if _observe_active else 0.0
	if ts > 0.0 or vg > 0.0:
		_mini_rect.visible = true
	else:
		later.append(func(): _mini_rect.visible = false)
	_to(_mini_mat, &"shader_parameter/strength", ts, duration)
	_to(_mini_mat, &"shader_parameter/vignette", vg, duration)
	_dof_on = _observe_active and q.dof and look.tilt_shift > 0.0
	_apply_dof(look, duration, later)
	set_process(ts > 0.0 or _dof_on)

	if _tween:
		_tween.finished.connect(func(): _run(later))
	else:
		_run(later)

	_sync_cards()
	if lamp_changed_now:
		lamp_changed.emit(lamp_on)


## Поворот солнца: азимут 0 = за окном северной стены (-Z), плюс к востоку (+X)
func _turn_sun(tod: TimeOfDayPreset, duration: float) -> void:
	var az := deg_to_rad(tod.sun_azimuth)
	var el := deg_to_rad(tod.sun_elevation)
	var to_sun := Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))
	var target := Basis.looking_at(-to_sun, Vector3.UP)   # -Z света смотрит по направлению луча
	if _tween and duration > 0.0:
		var q0 := _sun.global_basis.get_rotation_quaternion()
		var q1 := target.get_rotation_quaternion()
		_tween.tween_method(func(t: float): _sun.global_basis = Basis(q0.slerp(q1, t)), 0.0, 1.0, duration)
	else:
		_sun.global_basis = target


func _tint_sky(tod: TimeOfDayPreset, duration: float) -> void:
	var g := _sky_gradient()
	if g == null:
		return
	if _tween and duration > 0.0:
		var c0 := g.get_color(0)
		var c1 := g.get_color(1)
		_tween.tween_method(func(t: float):
			g.set_color(0, c0.lerp(tod.sky_top, t))
			g.set_color(1, c1.lerp(tod.sky_bottom, t)), 0.0, 1.0, duration)
	else:
		g.set_color(0, tod.sky_top)
		g.set_color(1, tod.sky_bottom)


func _sky_gradient() -> Gradient:
	if _sky == null:
		return null
	var m := _sky.material_override as StandardMaterial3D
	if m == null:
		return null
	var t := m.albedo_texture as GradientTexture2D
	if t == null:
		return null
	return t.gradient


## Карточки Observe показывают актуальное состояние, даже если оно сменилось из кода
func _sync_cards() -> void:
	if not is_instance_valid(_oc):
		return
	_oc.set_group_state(&"look", state.look)
	_oc.set_group_state(&"time", state.time)
	_oc.set_group_state(&"quality", state.quality)
	_oc.set_toggle_state(&"lamp", _lamp_is_on)


# ==========================================
# FAST DEBUG и ПРОИЗВОДИТЕЛЬНОСТЬ
# ==========================================

## Минимум для отладки: Low-настройки (тени, AA, SSAO quality), SDFGI и SSIL выключены, остальное как в сцене
func _apply_fast() -> void:
	state.quality = &"low"
	_apply_quality_settings()
	_env.sdfgi_enabled = false
	_env.ssil_enabled = false


func _toggle_vsync() -> void:
	var on := DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if on else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	print("[GFX] V-Sync ", "вкл" if on else "выкл")


## В debug раз в секунду пишет fps и состояние V-Sync в заголовок окна
func _debug_perf() -> void:
	if not Global.debug_mode:
		return
	var base := str(ProjectSettings.get_setting("application/config/name", "EC"))
	var t := Timer.new()
	t.wait_time = 1.0
	t.autostart = true
	t.timeout.connect(func():
		var vs := "vsync" if DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED else "no vsync"
		get_window().title = "%s | %d fps | %s | %s | lights %d/%d" % [base, Engine.get_frames_per_second(), vs, state.quality,
				light_budget.active, light_budget.wanted])
	add_child(t)


# ==========================================
# МИНИАТЮРА (S8)
# ==========================================

func _build_miniature() -> void:
	_mini_layer = CanvasLayer.new()
	_mini_layer.name = "MiniatureLayer"
	_mini_layer.layer = -2   # под контурами (-1) и UI (0)
	add_child(_mini_layer)
	var sh := Shader.new()
	sh.code = MINI_SHADER
	_mini_mat = ShaderMaterial.new()
	_mini_mat.shader = sh
	_mini_rect = ColorRect.new()
	_mini_rect.material = _mini_mat
	_mini_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mini_rect.visible = false
	_mini_layer.add_child(_mini_rect)
	# Именно set_anchors_and_offsets_preset: set_anchors_preset оставляет смещения (right=-ширина окна), прямоугольник схлопывался
	_mini_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## Observe включает и выключает миниатюру плавно
func _set_observe(on: bool) -> void:
	_observe_active = on
	_apply_all(0.5)


## Настоящий DOF (CameraAttributesPractical) на High: фокус на точке стола в центре кадра, см. _process
func _apply_dof(look: GraphicsPreset, duration: float, later: Array[Callable]) -> void:
	if _world_env == null:
		return
	if _dof_on:
		if _cam_attr == null:
			_cam_attr = CameraAttributesPractical.new()
		_world_env.camera_attributes = _cam_attr
		_cam_attr.dof_blur_far_enabled = true
		_cam_attr.dof_blur_near_enabled = true
		_to(_cam_attr, &"dof_blur_amount", 0.15 * look.tilt_shift, duration)
	elif _cam_attr:
		_to(_cam_attr, &"dof_blur_amount", 0.0, duration)
		later.append(func():
			_cam_attr.dof_blur_far_enabled = false
			_cam_attr.dof_blur_near_enabled = false)


## Включается только пока работает tilt-shift или DOF: сила tilt-shift по наклону камеры, фокус DOF по расстоянию
func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var fwd := -cam.global_basis.z
	# взгляд сверху (fwd.y -> -1) даёт полный эффект миниатюры, горизонтальный ослабляет
	_mini_mat.set_shader_parameter("pitch_scale", lerpf(0.35, 1.0, clampf(-fwd.y, 0.0, 1.0)))
	if _dof_on and _cam_attr:
		var d := 200.0
		var hit = Plane(Vector3.UP, 0.0).intersects_ray(cam.global_position, fwd)
		if hit != null:
			d = cam.global_position.distance_to(hit)
		d = clampf(d, 5.0, 400.0)
		_cam_attr.dof_blur_far_distance = d * 1.15
		_cam_attr.dof_blur_far_transition = d * 0.9
		_cam_attr.dof_blur_near_distance = d * 0.85
		_cam_attr.dof_blur_near_transition = d * 0.6


# ==========================================
# QUALITY: серверные настройки и файл настроек
# ==========================================

## То, что не относится к Environment: тени, AA, SSAO-quality, контуры. Применяется при смене tier
func _apply_quality_settings() -> void:
	var q: QualityPreset = qualities.get(state.quality)
	if q == null:
		return
	var vp := get_viewport()
	vp.msaa_3d = q.msaa as Viewport.MSAA
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if q.fxaa else Viewport.SCREEN_SPACE_AA_DISABLED
	vp.positional_shadow_atlas_size = q.positional_shadow_atlas
	RenderingServer.directional_shadow_atlas_set_size(q.dir_shadow_atlas, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(q.soft_shadow_quality as RenderingServer.ShadowQuality)
	RenderingServer.positional_soft_shadow_filter_set_quality(q.soft_shadow_quality as RenderingServer.ShadowQuality)
	RenderingServer.environment_set_ssao_quality(q.ssao_quality as RenderingServer.EnvironmentSSAOQuality,
			q.ssao_half_size, 0.5, 2, 50.0, 300.0)
	if _sun:
		match q.dir_shadow_splits:
			4:
				_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
			2:
				_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
			_:
				_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		_sun.directional_shadow_max_distance = q.dir_shadow_max_distance
		_sun.directional_shadow_blend_splits = q.dir_shadow_splits >= 2   # плавный переход между каскадами, без шва
	# SkyFill: один каскад на любом tier (параметры в EnvironmentRoot._ensure_sky_fill), тут только включаем тень
	Outline.mode = Outline.Mode.ALL if q.outlines_all else Outline.Mode.ESSENTIAL


## Грубый стартовый tier по имени видеокарты. Игрок меняет его в Observe, выбор запоминается
func _autodetect_quality() -> StringName:
	var gpu := RenderingServer.get_video_adapter_name().to_lower()
	var tier := &"medium"
	if gpu.contains("intel") or gpu.contains("uhd") or gpu.contains("iris") or gpu.contains("radeon graphics"):
		tier = &"low"
	elif gpu.contains("rtx") or gpu.contains("rx 6") or gpu.contains("rx 7") or gpu.contains("rx 9"):
		tier = &"high"
	if Global.debug_mode:
		print("[GFX] видеокарта: ", gpu, " -> tier ", tier)
	return tier


func _load_settings() -> void:
	var q := StringName(Settings.get_value("graphics", "quality", ""))
	state.quality = q if qualities.has(q) else _autodetect_quality()
	var l := StringName(Settings.get_value("graphics", "look", ""))
	if looks.has(l):
		state.look = l
	var t := StringName(Settings.get_value("graphics", "time", ""))
	if times.has(t):
		state.time = t
	# Ключа может не быть (первый запуск): get_value с null вместо умолчания дает ошибку, поэтому has_section_key
	if Settings.has_value("graphics", "track_shadows"):
		var ts = Settings.get_value("graphics", "track_shadows", false)
		if ts is bool:
			_track_shadows_override = 1 if ts else 0


func _save_settings() -> void:
	Settings.set_value("graphics", "quality", String(state.quality))
	Settings.set_value("graphics", "look", String(state.look))
	Settings.set_value("graphics", "time", String(state.time))
	if _track_shadows_override >= 0:
		Settings.set_value("graphics", "track_shadows", _track_shadows_override == 1)


# ==========================================
# ВНУТРЕННЕЕ
# ==========================================

func _load_presets() -> void:
	looks.clear()
	for id in GraphicsPreset.builtin_ids():
		looks[id] = GraphicsPreset.builtin(id)
	times.clear()
	for id in TimeOfDayPreset.builtin_ids():
		times[id] = TimeOfDayPreset.builtin(id)
	qualities.clear()
	for id in QualityPreset.builtin_ids():
		qualities[id] = QualityPreset.builtin(id)
	_load_dir(LOOKS_DIR, looks, GraphicsPreset)
	_load_dir(TIMES_DIR, times, TimeOfDayPreset)
	_load_dir(QUALITY_DIR, qualities, QualityPreset)


## .tres из папки переопределяют встроенные по id
func _load_dir(dir: String, into: Dictionary, type: Script) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		var fname := f.trim_suffix(".remap")   # в экспорте ресурсы имеют суффикс .remap
		if not fname.ends_with(".tres"):
			continue
		var r = load(dir + fname)
		if r != null and is_instance_of(r, type):
			into[r.id] = r


func _save_builtin(dir: String, ids: Array, make: Callable) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for id in ids:
		var path: String = dir + String(id) + ".tres"
		if FileAccess.file_exists(path):
			print("[GFX] уже есть, пропускаю: ", path)
			continue
		var err := ResourceSaver.save(make.call(id), path)
		print("[GFX] сохранён ", path, " (код ", err, ")")


## Паспорт текущей комнаты (RoomBuilder в группе room_root). null: комнаты нет (fast_debug)
func _room_config() -> RoomConfig:
	var rb := get_tree().get_first_node_in_group(&"room_root")
	return rb.get("config") as RoomConfig if rb else null


func _resolve() -> bool:
	_world_env = get_tree().get_first_node_in_group(&"gfx_env") as WorldEnvironment
	_env = _world_env.environment if _world_env else null
	_sun = get_tree().get_first_node_in_group(&"gfx_sun") as DirectionalLight3D
	_lamp = get_tree().get_first_node_in_group(&"gfx_lamp") as SpotLight3D
	_fill = get_tree().get_first_node_in_group(&"gfx_sky_fill") as DirectionalLight3D
	_probe = get_tree().get_first_node_in_group(&"gfx_probe") as ReflectionProbe
	if _sun:
		_sun_base_energy = _sun.light_energy
	if _env == null:
		if not _scene_without_gfx():
			push_warning("GFX: нет WorldEnvironment в группе gfx_env (добавьте EnvironmentRoot в сцену или свою ноду в группу)")
		return false
	return true


func _connect_observe() -> void:
	_oc = get_tree().get_first_node_in_group(&"observe_controller")
	if _oc:
		_oc.observe_action.connect(_on_observe_action)
		_oc.observe_entered.connect(func(): _set_observe(true))
		_oc.observe_exited.connect(_on_observe_exited)
		_sync_cards()
	elif not _scene_without_gfx():
		push_warning("GFX: ObserveController не найден, карточки Look и Light не работают")


## Вышли из Observe: Lab выключается (комната и камера возвращаются к обычным), затем миниатюра гаснет
func _on_observe_exited() -> void:
	_observe_active = false
	exit_lab()
	_set_observe(false)


## Сцены-инструменты (Icon Studio) без окружения игры помечают корень метой gfx_optional: предупреждения GFX там не нужны
func _scene_without_gfx() -> bool:
	var cs := get_tree().current_scene
	return cs != null and cs.has_meta(&"gfx_optional")


## ⚡Сигнал из ObserveController
func _on_observe_action(_cat: StringName, _id: StringName, _pressed: bool) -> void:
	match _cat:
		&'look':
			if _id == &'lab':
				if lab_mode:
					lab.rebuild()   # уже в Lab: чистый дефолт заново
				else:
					enter_lab()
			elif _pressed and looks.has(_id):
				apply_look(_id)
			elif _pressed and qualities.has(_id):
				apply_quality(_id)
		&'light':
			if _id == &'lamp':
				set_lamp(_pressed)
			elif _pressed and times.has(_id):
				apply_time(_id)


## Ищет булево свойство по ключевым словам в имени
func _find_bool_prop(obj: Object, keys: Array) -> StringName:
	if obj == null:
		return &""
	for pr in obj.get_property_list():
		if pr.type != TYPE_BOOL:
			continue
		var n: String = String(pr.name).to_lower()
		for k in keys:
			if n.contains(k):
				return StringName(pr.name)
	return &""


func _has_kw(n: String, kw: Array) -> bool:
	var l := n.to_lower()
	for k in kw:
		if l.contains(k):
			return true
	return false


func _discover_features() -> void:
	# Multi-bounce AO в 4.8 beta 1 встроен в SSAO без переключателя (в Environment свойства нет).
	# Поиск оставлен молча на случай, если в stable появится свойство
	_p_ao_multibounce = _find_bool_prop(_env, ["multibounce", "multi_bounce"])
	_p_contact_env = _find_bool_prop(_env, ["contact"])
	_p_contact_sun = _find_bool_prop(_sun, ["contact_shadows_allow", "contact"])
	
	#if Global.debug_mode:
	#	print("[GFX] contact shadows (sun): ", str(_p_contact_sun) if _p_contact_sun != &"" else "НЕ НАЙДЕНО",
	#			" | multi-bounce AO переключатель: ", str(_p_ao_multibounce) if _p_ao_multibounce != &"" else "нет (встроен в SSAO)")
	#if _sun and _p_contact_sun == &"":
	#	push_warning("GFX: свойство contact shadows на DirectionalLight3D не найдено (GFX.dump_props() покажет кандидатов)")


func _set_feature(obj: Object, prop: StringName, on: bool) -> void:
	if obj != null and prop != &"":
		obj.set(prop, on)


## Включаем эффект сразу, выключаем в конце перехода
func _flag(obj: Object, prop: StringName, on: bool, later: Array[Callable]) -> void:
	if on:
		obj.set(prop, true)
	elif obj.get(prop):
		later.append(func(): obj.set(prop, false))


func _to(obj: Object, prop: StringName, value: Variant, duration: float) -> void:
	if obj == null:
		return
	if _tween and duration > 0.0:
		_tween.tween_property(obj, NodePath(String(prop)), value, duration)
	else:
		obj.set(prop, value)


func _run(calls: Array[Callable]) -> void:
	for c in calls:
		c.call()
