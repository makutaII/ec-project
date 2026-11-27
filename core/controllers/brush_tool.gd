class_name BrushTool extends Node

# XX claude-terra 13.14 H2 (новый файл)
##########################
## Кисть рельефа (ATTN_13 §13.14): холм и яма, выравнивание, гравий, скалы. Меняет поле высот TGM.field.
##########################
## Модель «площадка + склон» (FieldBrush, спайк H0). Кисть описана ресурсом TerrainBrush в карточке каталога (тип поверхности, угол, радиус).
## Ввод: Ctrl+колесо подъём или яма вокруг курсора (с Shift до целого слоя), Alt+колесо радиус (запасной вариант: `,` и `.`),
## `[` и `]` угол склона (Shift ×5), ЛКМ с удержанием подтягивает поле под площадкой к высоте точки нажатия (одна правка на весь драг),
## Ctrl+Z отменяет последнюю правку поля, ПКМ выход. Мазок трогает только область стола (TGM.field_table_polygons).
## Кольца кисти: голубое площадка, жёлтое край склона, белое радиус. Оранжевое: угол смягчён, склон не вмещается в кисть.
## Яма не глубже слоя шпатлёвки (на нуле толщины слоя нет), пол (стол, верх листа) не трогается.
## Пределы (H3): холм упирается в низ листа над ним (потолок), см. FieldBrush. Объекты в зоне (клавиша X переключает): игнорировать,
## обходить (узлы под объектом не меняются), поднимать (объект садится на новую высоту рельефа; Ctrl+Z возвращает и объект).

const MSG_TIME := 2.5
const RING_POINTS := 48
const RING_LIFT := 0.08
const COL_PLATEAU := Color(0.45, 0.95, 1.0)
const COL_SLOPE := Color(1.0, 0.9, 0.35)
const COL_RADIUS := Color(1.0, 1.0, 1.0, 0.45)
const COL_LIMIT := Color(1.0, 0.55, 0.25)
## Не чаще раза в это время пересчитываем план для колец, с
const PREVIEW_PERIOD := 0.1
const CLIP_PERIOD := 0.5
const OBJ_NAMES: Array[String] = ["игнорировать", "обходить", "поднимать"]
## Прямоугольник «весь мир» для первого сбора объектов (дальше фильтр по зоне мазка)
const WORLD := Rect2(-1.0e5, -1.0e5, 2.0e5, 2.0e5)
const ANGLE_STEP := 5.0
const RADIUS_STEP := 0.5

var controller: ToolController
## Описание кисти (TerrainBrush из карточки). Ставит ToolController до enter()
var brush: TerrainBrush

## Режим объектов в зоне, выбранный игроком клавишей X: помнится между включениями кисти (-1: не выбирали, берётся из карточки)
static var last_objects_mode := -1

var _fb := FieldBrush.new()
var _hover := Vector3.ZERO
var _hover_ok := false
var _leveling := false
var _anchor := 0.0
var _clip: Array = []
var _clip_t := 0.0
var _objs: Array = []                # объекты на земле (FieldObjects.collect), обновляются вместе с _clip
var _lift: Dictionary = {}           # Entity -> на сколько кисть подняла объект за открытую правку
var _prev_t := 0.0
var _prev_key := ""
var _plan := {}
var _rmb_pos := Vector2.ZERO
var _msg := ""
var _msg_t := 0.0

## H2d: настройки игрока поверх карточки (панель «Инструмент», ToolSettings). На сессию, по кистям: ключ карточки -> значения
static var saved := {}
var _card_surfaces: Array[FieldSurface] = []   # поверхности карточки
var _mat_choice := -1                          # -1 материал как в карточке, иначе слот палитры FieldMaterials
var _settings_ver := 0                         # растёт, когда набор строк панели надо собрать заново

var _mi: MeshInstance3D
var _imm: ImmediateMesh


func enter() -> void:
	_fb = FieldBrush.new()
	_fb.load_brush(brush)
	if last_objects_mode >= 0:
		_fb.objects_mode = last_objects_mode
	_restore_settings()
	_fb.ceiling_fn = Callable(TGM, "field_ceilings")
	_leveling = false
	_hover_ok = false
	_plan = {}
	_prev_key = ""
	_clip = TGM.field_table_polygons()
	_refresh_objects()
	_ensure_preview()
	controller.publish_selection(null)
	controller.publish_tool_settings(self)   # H2d: настройки кисти в InfoPanel


func exit(_to_drag: bool = false) -> void:
	_finish_level()
	controller.clear_tool_settings(self)
	if is_instance_valid(_mi):
		_mi.queue_free()
	InfoTips.clear(self)
	_mi = null
	_imm = null
	controller.select_build_object(null)   # снять нажатие с кнопки каталога


func _brush_title() -> String:
	return "Кисть · %s%s" % [_fb.type_label(), " · только краска" if _fb.paint_only else ""]


## --- Настройки в InfoPanel (H2d, контракт ToolSettings) ---

func settings_title() -> String:
	return _brush_title()


func settings_version() -> int:
	return _settings_ver


func get_info_sections() -> Array[InfoSection]:
	var mat_ids: Array = [-1]
	var mat_titles: Array = ["Как в карточке"]
	var pal := FieldMaterials.shared()
	if pal != null:
		for i in pal.slots().size():
			mat_ids.append(i)
			mat_titles.append(pal.slot_title(i))
	var form := InfoSection.make("Форма кисти", [
		InfoSection.slider("Радиус, ю", _fb.radius_min, _fb.radius_max, RADIUS_STEP, Callable(self, "_get_radius"), Callable(self, "_set_radius")),
		InfoSection.slider("Угол склона, °", 5.0, 90.0, ANGLE_STEP, Callable(self, "_get_angle"), Callable(self, "_set_angle")),
		InfoSection.list("Объекты в зоне", [0, 1, 2], OBJ_NAMES, Callable(self, "_get_objects"), Callable(self, "_set_objects")),
	])
	var relief := InfoSection.make("Рельеф", [
		InfoSection.slider("Шаг щелчка, слоёв", 0.05, 1.0, 0.05, Callable(self, "_get_notch"), Callable(self, "_set_notch")),
		InfoSection.slider("Предел толщины, слоёв", 1.0, 31.0, 1.0, Callable(self, "_get_max_layers"), Callable(self, "_set_max_layers")),
		InfoSection.slider("Сила подтягивания", 0.1, 1.0, 0.05, Callable(self, "_get_strength"), Callable(self, "_set_strength")),
		InfoSection.slider("Мин. площадка, ю", 0.5, 5.0, 0.5, Callable(self, "_get_plateau"), Callable(self, "_set_plateau")),
		InfoSection.slider("Допуск склона, доля радиуса", 0.0, 1.0, 0.05, Callable(self, "_get_tol_frac"), Callable(self, "_set_tol_frac")),
		InfoSection.slider("Допуск склона, макс. ю", 0.0, 6.0, 0.5, Callable(self, "_get_tol_max"), Callable(self, "_set_tol_max")),
	])
	var surface := InfoSection.make("Поверхность", [
		InfoSection.list("Материал", mat_ids, mat_titles, Callable(self, "_get_material"), Callable(self, "_set_material")),
		InfoSection.toggle("Только краска", Callable(self, "_get_paint_only"), Callable(self, "_set_paint_only")),
		InfoSection.slider("Непрозрачность", 0.0, 1.0, 0.05, Callable(self, "_get_opacity"), Callable(self, "_set_opacity")),
		InfoSection.slider("Перо, ю", 0.0, 3.0, 0.1, Callable(self, "_get_feather"), Callable(self, "_set_feather")),
		InfoSection.slider("Переход, ю", 0.0, FieldSurface.BLEND_MAX, 0.05, Callable(self, "_get_blend"), Callable(self, "_set_blend")),
		InfoSection.list("Фактура рельефа", [-1, 0, 1, 2], ["Как у материала", "Гладкая", "Каменистая", "Скалистая"], Callable(self, "_get_kind"), Callable(self, "_set_kind")),
		InfoSection.button("Сбросить к карточке", Callable(self, "_settings_reset")),
	])
	var keys := InfoSection.make("Клавиши", [
		InfoSection.note("Alt+колесо или , и .: радиус. Ctrl+колесо: подъём или яма (Shift: до целого слоя)"),
		InfoSection.note("%s и %s: угол склона (Shift ×5). %s: объекты в зоне. %s: отмена правки" % [Actions.key_text(&"width_down"), Actions.key_text(&"width_up"), Actions.key_text(&"brush_objects"), Actions.key_text(&"tool_undo")]),
	])
	return [form, relief, surface, keys]


func _touch() -> void:
	_prev_key = ""
	_remember_settings()


func _get_radius() -> float:
	return _fb.radius


func _set_radius(v: float) -> void:
	_fb.radius = clampf(v, _fb.radius_min, _fb.radius_max)
	_touch()


func _get_angle() -> float:
	return _fb.angle


func _set_angle(v: float) -> void:
	_fb.angle = clampf(v, 5.0, 90.0)
	_touch()


func _get_objects() -> Variant:
	return _fb.objects_mode


func _set_objects(v: Variant) -> void:
	_fb.objects_mode = clampi(int(v), FieldBrush.OBJ_IGNORE, FieldBrush.OBJ_LIFT)
	last_objects_mode = _fb.objects_mode
	_refresh_objects()
	_touch()


func _get_notch() -> float:
	return _fb.notch_layers


func _set_notch(v: float) -> void:
	_fb.notch_layers = clampf(v, 0.05, 1.0)
	_touch()


func _get_max_layers() -> float:
	return _fb.max_layers


func _set_max_layers(v: float) -> void:
	_fb.max_layers = clampf(v, 1.0, 31.0)
	_touch()


func _get_strength() -> float:
	return _fb.strength


func _set_strength(v: float) -> void:
	_fb.strength = clampf(v, 0.1, 1.0)
	_touch()


func _get_plateau() -> float:
	return _fb.plateau_min


func _set_plateau(v: float) -> void:
	_fb.plateau_min = clampf(v, 0.5, 5.0)
	_touch()


func _get_tol_frac() -> float:
	return _fb.tol_frac


func _set_tol_frac(v: float) -> void:
	_fb.tol_frac = clampf(v, 0.0, 1.0)
	_touch()


func _get_tol_max() -> float:
	return _fb.tol_max


func _set_tol_max(v: float) -> void:
	_fb.tol_max = clampf(v, 0.0, 6.0)
	_touch()


func _get_material() -> Variant:
	return _mat_choice


func _set_material(v: Variant) -> void:
	_mat_choice = int(v)
	_apply_material()
	_touch()


func _get_paint_only() -> bool:
	return _fb.paint_only


func _set_paint_only(on: bool) -> void:
	_fb.paint_only = on
	_touch()


func _get_opacity() -> float:
	return _fb.opacity_now()


func _set_opacity(v: float) -> void:
	_fb.ov_opacity = clampf(v, 0.0, 1.0)
	_fb.reapply_surfaces()
	_touch()


func _get_feather() -> float:
	return _fb.feather_now()


func _set_feather(v: float) -> void:
	_fb.ov_feather = maxf(v, 0.0)
	_fb.reapply_surfaces()
	_touch()


func _get_blend() -> float:
	return _fb.blend_now()


func _set_blend(v: float) -> void:
	_fb.ov_blend = clampf(v, 0.0, FieldSurface.BLEND_MAX)
	_fb.reapply_surfaces()
	_touch()


func _get_kind() -> Variant:
	return _fb.ov_kind


func _set_kind(v: Variant) -> void:
	_fb.ov_kind = clampi(int(v), -1, TerrainField.ROCK)
	_fb.reapply_surfaces()
	_touch()


## Поверхности кисти по выбору материала: -1 как в карточке, иначе одна поверхность из палитры
func _apply_material() -> void:
	var list: Array[FieldSurface] = []
	var pal := FieldMaterials.shared()
	if _mat_choice >= 0 and pal != null and _mat_choice < pal.slots().size():
		list.append(pal.slots()[_mat_choice])
	else:
		_mat_choice = -1
		list.assign(_card_surfaces)
	_fb.set_surfaces(list)


func _brush_key() -> String:
	if brush == null:
		return ""
	return brush.resource_path if not brush.resource_path.is_empty() else str(brush.get_instance_id())


func _remember_settings() -> void:
	saved[_brush_key()] = {
		"radius": _fb.radius, "angle": _fb.angle, "notch": _fb.notch_layers, "max_layers": _fb.max_layers,
		"strength": _fb.strength, "plateau": _fb.plateau_min, "tol_frac": _fb.tol_frac, "tol_max": _fb.tol_max,
		"mat": _mat_choice, "paint_only": _fb.paint_only,
		"ov_opacity": _fb.ov_opacity, "ov_feather": _fb.ov_feather, "ov_blend": _fb.ov_blend, "ov_kind": _fb.ov_kind,
	}


## Настройки, сделанные игроком в этой сессии, возвращаются поверх карточки (enter)
func _restore_settings() -> void:
	_card_surfaces.assign(brush.surfaces if brush != null else [])
	_mat_choice = -1
	var d: Dictionary = saved.get(_brush_key(), {})
	if d.is_empty():
		return
	_fb.radius = clampf(float(d.get("radius", _fb.radius)), _fb.radius_min, _fb.radius_max)
	_fb.angle = clampf(float(d.get("angle", _fb.angle)), 5.0, 90.0)
	_fb.notch_layers = clampf(float(d.get("notch", _fb.notch_layers)), 0.05, 1.0)
	_fb.max_layers = clampf(float(d.get("max_layers", _fb.max_layers)), 1.0, 31.0)
	_fb.strength = clampf(float(d.get("strength", _fb.strength)), 0.1, 1.0)
	_fb.plateau_min = clampf(float(d.get("plateau", _fb.plateau_min)), 0.5, 5.0)
	_fb.tol_frac = clampf(float(d.get("tol_frac", _fb.tol_frac)), 0.0, 1.0)
	_fb.tol_max = clampf(float(d.get("tol_max", _fb.tol_max)), 0.0, 6.0)
	_fb.paint_only = bool(d.get("paint_only", false))
	_fb.ov_opacity = float(d.get("ov_opacity", -1.0))
	_fb.ov_feather = float(d.get("ov_feather", -1.0))
	_fb.ov_blend = float(d.get("ov_blend", -1.0))
	_fb.ov_kind = int(d.get("ov_kind", -1))
	_mat_choice = int(d.get("mat", -1))
	_apply_material()


## Кнопка «Сбросить к карточке»: всё, что менял игрок, возвращается к значениям карточки
func _settings_reset() -> void:
	saved.erase(_brush_key())
	_fb.ov_opacity = -1.0
	_fb.ov_feather = -1.0
	_fb.ov_blend = -1.0
	_fb.ov_kind = -1
	_fb.paint_only = false
	_mat_choice = -1
	last_objects_mode = -1
	_fb.load_brush(brush)
	_settings_ver += 1
	_prev_key = ""
	_say("Настройки кисти сброшены к карточке")


## --- Ввод ---

func handle_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb:
		match mb.button_index:
			MOUSE_BUTTON_RIGHT:
				if mb.pressed:
					_rmb_pos = mb.position
				elif _rmb_pos.distance_to(mb.position) < 5:   # короткий клик, а не сдвиг камеры
					controller.switch_tool(controller.select_tool)
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_start_level()
				else:
					_finish_level()
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_on_wheel(mb)
		return

	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if Actions.pressed(event, &"tool_undo"):
		_undo()
		return
	if Actions.pressed_shift_ok(event, &"brush_objects"):
		_fb.objects_mode = (_fb.objects_mode + 1) % OBJ_NAMES.size()
		last_objects_mode = _fb.objects_mode
		_remember_settings()
		_refresh_objects()
		_prev_key = ""
		_say("Объекты в зоне: %s" % OBJ_NAMES[_fb.objects_mode])
		if Global.debug_mode:
			_print_objects()
		return
	var a := Actions.axis_step(event, &"width_up", &"width_down", 5)
	if a != 0:
		_fb.angle = clampf(_fb.angle + float(a) * ANGLE_STEP, 5.0, 90.0)
		_remember_settings()
		_prev_key = ""
		_say("Угол склона %.0f°" % _fb.angle)
		return
	# запасной ввод радиуса: на некоторых оконных менеджерах Alt+колесо перехватывается системой
	if k.physical_keycode == KEY_PERIOD or k.physical_keycode == KEY_COMMA:
		_change_radius(1.0 if k.physical_keycode == KEY_PERIOD else -1.0)


func _on_wheel(mb: InputEventMouseButton) -> void:
	var up := mb.button_index == MOUSE_BUTTON_WHEEL_UP
	if mb.ctrl_pressed:
		get_viewport().set_input_as_handled()   # зум камеры на это колесо не нужен
		_raise(1.0 if up else -1.0, mb.shift_pressed)
	elif mb.alt_pressed:
		get_viewport().set_input_as_handled()
		_change_radius(1.0 if up else -1.0)


func _change_radius(dir_: float) -> void:
	_fb.radius = clampf(_fb.radius + dir_ * RADIUS_STEP, _fb.radius_min, _fb.radius_max)
	_remember_settings()
	_prev_key = ""
	_say("Радиус кисти %.1f ю" % _fb.radius)


func _undo() -> void:
	if _leveling:
		return
	if TGM.field.undo():
		TGM.field_reclip()
		_prev_key = ""
		_say("Правка отменена")
	else:
		_say("Отменять нечего")


## --- Подъём и яма ---

## Щелчок Ctrl+колеса: площадка на notch_layers выше или ниже поверхности под курсором (whole: до целого слоя)
func _raise(dir_: float, whole: bool) -> void:
	if not _hover_ok or _leveling:
		return
	if _fb.paint_only:
		_say("Режим «только краска»: рельеф не меняется")
		return
	var f := TGM.field
	var c := Vector2(_hover.x, _hover.z)
	var hc := f.sample(c.x, c.y)
	var fc := f.floor_at(roundi(c.x / TerrainField.STEP), roundi(c.y / TerrainField.STEP))
	var ht := _fb.next_height(hc, dir_, whole, f.layer_height, fc, _ceil_at(c))
	if absf(ht - hc) < 0.0001:
		_say(("Выше некуда" if _ceil_at(c) > hc + 0.0001 else "Выше нельзя: лист над кистью") if dir_ > 0.0 else "Глубже слоя не копаем")
		return
	_clip = TGM.field_table_polygons()
	_refresh_objects()
	f.layer_height = float(Global.settings.layer_height)
	f.begin_edit()
	var changed := _stroke(c, ht, int(dir_), 1.0)
	_commit_lift()
	f.end_edit()
	_plan = _fb.last_plan
	if not changed:
		_say("Здесь нечего менять")
	_prev_key = ""


## --- Пределы и объекты (H3) ---

## Потолок над точкой c (мир Y): низ листа над ней, INF если листа нет
func _ceil_at(c: Vector2) -> float:
	var r := Rect2i(roundi(c.x / TerrainField.STEP), roundi(c.y / TerrainField.STEP), 1, 1)
	var a := TGM.field_ceilings(r)
	return INF if a.is_empty() else a[0]


## Собрать объекты на земле заново (кроме режима «игнорировать»: тогда они кисти не нужны)
func _refresh_objects() -> void:
	if _fb.objects_mode == FieldBrush.OBJ_IGNORE:
		_objs = []
	else:
		_objs = TGM.field_objects(WORLD)
	_fb.obstacles = FieldObjects.polys_of(_objs) if _fb.objects_mode == FieldBrush.OBJ_BYPASS else []


## Отладка (Global.debug_mode, клавиша X): какие объекты кисть видит и какого размера их след
func _print_objects() -> void:
	print("[BrushTool] объектов на земле: %d" % _objs.size())
	for o: Dictionary in _objs:
		var bb := C_Contour.bounds_of(o["poly"])
		print("  %s  след %.1f x %.1f ю" % [(o["entity"] as Entity).name, bb.size.x, bb.size.y])


## Высота, на которой объект стоит на земле: самая высокая точка поля под его опорными точками
func _rest_y(o: Dictionary) -> float:
	var y := -INF
	for p: Vector2 in o["pts"]:
		y = maxf(y, TGM.field.sample(p.x, p.y))
	return y


## Мазок поля. В режиме «поднимать» объекты в зоне мазка двигаются на то, на сколько изменилась высота под ними
func _stroke(c: Vector2, ht: float, mode: int, kk: float) -> bool:
	var f := TGM.field
	var near: Array = []
	var before: Array[float] = []
	if _fb.objects_mode == FieldBrush.OBJ_LIFT and not _objs.is_empty():
		var tol := minf(_fb.radius * _fb.tol_frac, _fb.tol_max)
		var zone := Rect2(c, Vector2.ZERO).grow(_fb.radius + tol + FieldObjects.MARGIN)
		for o: Dictionary in _objs:
			var e := o["entity"] as Entity
			if not is_instance_valid(e):
				continue
			if C_Contour.bounds_of(o["poly"]).intersects(zone):
				near.append(o)
				before.append(_rest_y(o))
	var changed := _fb.stroke(f, c, ht, mode, kk, _clip)
	if changed:
		for n in near.size():
			var o: Dictionary = near[n]
			var d := _rest_y(o) - before[n]
			if absf(d) < 0.0001:
				continue
			var e := o["entity"] as Entity
			e.global_position.y += d
			_lift[e] = float(_lift.get(e, 0.0)) + d
	return changed


## Закрыть подъём объектов: сумма сдвигов правки привязывается к ней, Ctrl+Z вернёт объекты вместе с полем. Вызывать до field.end_edit
func _commit_lift() -> void:
	if _lift.is_empty():
		return
	var moved := _lift
	_lift = {}
	TGM.field.attach_undo(_undo_lift.bind(moved))


## Отмена правки: объекты, поднятые этой правкой, опускаются обратно
func _undo_lift(moved: Dictionary) -> void:
	for k: Variant in moved:
		var e := k as Entity
		if is_instance_valid(e):
			e.global_position.y -= float(moved[k])


## --- Выравнивание ЛКМ ---

func _start_level() -> void:
	if not _hover_ok or _leveling:
		return
	var f := TGM.field
	f.layer_height = float(Global.settings.layer_height)
	_anchor = f.sample(_hover.x, _hover.z)
	_clip = TGM.field_table_polygons()
	_refresh_objects()
	_leveling = true
	f.begin_edit()


func _finish_level() -> void:
	if not _leveling:
		return
	_leveling = false
	_commit_lift()
	TGM.field.end_edit()
	_prev_key = ""


func _say(text: String) -> void:
	_msg = text
	_msg_t = MSG_TIME
	_prev_key = ""


## --- Тик ---

func process_tick(delta: float) -> void:
	if Global.current_mode != &"build":
		controller.switch_tool(controller.select_tool)
		return
	if _msg_t > 0.0:
		_msg_t -= delta
		if _msg_t <= 0.0:
			_msg = ""
			_prev_key = ""
	if _leveling and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_finish_level()   # отпускание пришло над UI
	_clip_t += delta
	if _clip_t >= CLIP_PERIOD and not _leveling:
		_clip_t = 0.0
		_clip = TGM.field_table_polygons()
		_refresh_objects()
	_update_hover()
	if _leveling and _hover_ok:
		var kk := 1.0 - exp(-FieldBrush.PULL_RATE * _fb.strength * delta)
		TGM.field.layer_height = float(Global.settings.layer_height)
		_stroke(Vector2(_hover.x, _hover.z), _anchor, 0, kk)
		_plan = _fb.last_plan
		_redraw()
		return
	_prev_t += delta
	if _prev_t >= PREVIEW_PERIOD:
		_prev_t = 0.0
		_update_preview()


func _update_hover() -> void:
	if _leveling:
		var ph := controller.get_mouse_plane_hit(_anchor)
		if ph.is_empty():
			return
		_hover = ph.position
		_hover_ok = true
		return
	var hit := controller.get_mouse_ray(Global.active_layers(["ground"]))
	if hit.is_empty():
		if _hover_ok:
			_hover_ok = false
			_prev_key = ""
			_hide_preview()
		return
	_hover = hit.position
	_hover_ok = true


## План для колец: следующий щелчок вверх в точке под курсором. Пересчёт только когда сменилась ячейка, радиус, угол или поле
func _update_preview() -> void:
	if not _hover_ok:
		return
	var f := TGM.field
	var c := Vector2(_hover.x, _hover.z)
	var key := "%d,%d|%.1f|%.0f|%d|%d" % [roundi(c.x / TerrainField.STEP), roundi(c.y / TerrainField.STEP), _fb.radius, _fb.angle, hash(_msg), _fb.objects_mode]
	if key == _prev_key:
		return
	_prev_key = key
	f.layer_height = float(Global.settings.layer_height)
	var hc := f.sample(c.x, c.y)
	var fc := f.floor_at(roundi(c.x / TerrainField.STEP), roundi(c.y / TerrainField.STEP))
	var ht := _fb.next_height(hc, 1.0, false, f.layer_height, fc, _ceil_at(c))
	_plan = _fb.preview(f, c, ht, 1, _clip)
	_redraw()


## --- Превью ---

func _ensure_preview() -> void:
	if is_instance_valid(_mi):
		return
	_imm = ImmediateMesh.new()
	_mi = MeshInstance3D.new()
	_mi.name = "BrushToolPreview"
	_mi.mesh = _imm
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	_mi.material_override = m
	add_child(_mi)


func _hide_preview() -> void:
	if _imm:
		_imm.clear_surfaces()
	InfoTips.clear(self)


func _redraw() -> void:
	if _imm == null:
		return
	_imm.clear_surfaces()
	if not _hover_ok or _plan.is_empty():
		_hide_preview()
		return
	var f := TGM.field
	var c := Vector2(_hover.x, _hover.z)
	var limited: bool = str(_plan["limit"]) == "место"
	_imm.surface_begin(Mesh.PRIMITIVE_LINES)
	_ring(f, c, float(_plan["p"]), COL_PLATEAU)
	_ring(f, c, float(_plan["e"]), COL_LIMIT if limited else COL_SLOPE)
	_ring(f, c, _fb.radius, COL_RADIUS)
	_imm.surface_end()
	_update_note()


func _ring(f: TerrainField, c: Vector2, r: float, col: Color) -> void:
	var prev := Vector3.ZERO
	for n in RING_POINTS + 1:
		var a := TAU * float(n) / float(RING_POINTS)
		var x := c.x + cos(a) * r
		var z := c.y + sin(a) * r
		var v := Vector3(x, f.sample(x, z) + RING_LIFT, z)
		if n > 0:
			_imm.surface_set_color(col)
			_imm.surface_add_vertex(prev)
			_imm.surface_set_color(col)
			_imm.surface_add_vertex(v)
		prev = v


func _limit_text() -> String:
	var lim := str(_plan.get("limit", ""))
	if lim == "место":
		return "угол смягчён: склон не вмещается в кисть. Увеличьте радиус"
	if lim == "сетка":
		return "склон не уже одной ячейки"
	return ""


func _update_note() -> void:
	if _imm == null:
		return
	var f := TGM.field
	var hc := f.sample(_hover.x, _hover.z)
	var lines: Array = [InfoTips.title("%s · радиус %.1f ю · угол %.0f° · объекты: %s" % [_brush_title(), _fb.radius, _fb.angle, OBJ_NAMES[_fb.objects_mode]])]
	lines.append(InfoTips.info("высота %.2f слоя · площадка %.1f ю, склон %.1f ю, угол склона %.0f°" % [
		hc / maxf(f.layer_height, 0.001), float(_plan["p"]), float(_plan["w"]), float(_plan["ang"])]))
	var lim := _limit_text()
	if _msg != "":
		lines.append(InfoTips.warn(_msg))
	elif lim != "":
		lines.append(InfoTips.warn(lim))
	elif bool(_plan.get("ceiling", false)):
		lines.append(InfoTips.warn("холм упирается в лист над ним"))
	elif bool(_plan.get("locked", false)):
		lines.append(InfoTips.dim("под объектом узлы не меняются"))
	elif _leveling:
		lines.append(InfoTips.dim("выравнивание"))
	InfoTips.show_lines(self, lines)
