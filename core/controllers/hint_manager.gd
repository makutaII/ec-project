extends Node
# class_name не задаём: это синглтон Hints (autoload)

###########################
##💡 Hints - подсказки игроку внизу экрана (TDD §16)
############################
## Показывает одну-две строки с клавишами для текущего режима и инструмента.
## Источники состояния (никто сюда не пишет текст, только сообщает контекст):
##   set_mode(mode)        ToolController при смене режима (build, operate, observe, library)
##   set_tool(tool_name)   ToolController при смене инструмента (SelectTool, BuildTool, DragTool, ObserveTool)
##   set_context(key, on)  SelectTool: "selected" (есть выбранный объект), ObserveCameraRig: "photo" (UI скрыт)
##   set_extra(name)       ObserveCameraRig: режим камеры follow, pov, orbit или ""
## Тексты лежат в HINTS ниже: правятся только там. Клавиша действия пишется токеном «@id» (@rotate_left/@rotate_right → «Q/E»),
## настоящая клавиша берётся из InputMap через Actions.key_text, поэтому после переназначения подсказка меняется сама.
## Жесты с мышью и модификаторами (Shift+ЛКМ, Alt + мышь) берутся из реестра токеном «@gesture_...»; прочий текст проходит как есть. Ключ "режим/контекст" перекрывает общий "контекст".
## Включение сохраняется через Settings ([ui] hints_enabled), кнопка в меню верхней панели.

signal enabled_changed(on: bool)

const KEY_COLOR := "#ffd54a"
const DIM_COLOR := "#9aa4b2"
const BOTTOM_MARGIN := 14.0
const MAX_WIDTH := 960.0
## По бокам нижней подсказки не заходим на DC (417) и правую колонку: ширина DC + отступ с каждой стороны.
const SIDE_RESERVE := 429.0
const SEPARATOR := "   ·   "

## Пары [клавиша, действие]
const HINTS := {
	"select_group": [["@gesture_add_select", "добавить / убрать объект"], ["@gesture_marquee_add", "добавить рамкой"], ["@delete", "удалить выбранное"], ["Галки в панели", "какие категории в группе"], ["ПКМ", "снять выбор"], ["Тащить ЛКМ по объекту группы", "двигать группу"], ["@gesture_marquee", "новая рамка"]],
	"select_none": [["ЛКМ", "выбрать объект"], ["ЛКМ по рычагу", "переложить стрелку (ручную)"], ["Рамка", "ЛКМ тащить по пустому месту (Ctrl: поверх объектов)"], ["Категория → объект", "построить новый"], ["@duplicate_last", "дубль последнего"]],
	"operate/select_none": [["ЛКМ", "выбрать вагон или локомотив"], ["ЛКМ по рычагу", "переложить стрелку (ручную)"], ["Тащить ЛКМ", "переместить выбранный"]],
	"select_sel": [["Тащить ЛКМ", "переместить"], ["@gesture_add_select", "добавить к выбору"], ["@duplicate_last", "дубль выбранного"], ["@delete", "удалить"], ["@wagon_kick_fwd/@wagon_kick_back", "пинок вагона"], ["@tunnel_toggle", "тоннель (трак)"], ["@embankment_toggle", "насыпь (трак)"], ["@flex_zones_toggle", "зоны flex"]],
	"select_switch": [["Тащить ЛКМ", "переместить"], ["@gesture_add_select", "добавить к выбору"], ["@duplicate_last", "дубль выбранного"], ["@delete", "удалить"], ["@wagon_kick_fwd/@wagon_kick_back", "пинок вагона"], ["@tunnel_toggle", "тоннель (трак)"], ["@embankment_toggle", "насыпь (трак)"], ["@flex_zones_toggle", "зоны flex"], ["@switch_throw", "переложить стрелку (дистанционную)"], ["ЛКМ по рычагу", "переложить стрелку (ручную)"]],
	"operate/select_sel": [["Ручка на панели", "ЛКМ вращать, ПКМ обнулить"], ["@wagon_kick_fwd/@wagon_kick_back", "пинок вагона"], ["Тащить ЛКМ", "переместить"], ["@delete", "удалить"]],
	"operate/select_switch": [["Ручка на панели", "ЛКМ вращать, ПКМ обнулить"], ["@wagon_kick_fwd/@wagon_kick_back", "пинок вагона"], ["Тащить ЛКМ", "переместить"], ["@delete", "удалить"], ["@switch_throw", "переложить стрелку (дистанционную)"], ["ЛКМ по рычагу", "переложить стрелку (ручную)"]],
	"build": [["ЛКМ", "построить"], ["ПКМ", "отмена"], ["@rotate_left/@rotate_right", "поворот {rot}° (Shift: 5°)"], ["@gesture_rotate", "вращать (Shift: точнее)"], ["@gesture_height", "высота"], ["@level_up/@level_down", "уровень"], ["Shift+@level_up/@level_down, @level_up_x5/@level_down_x5", "уровень ×5"], ["@duplicate_last", "дубль последнего"], ["@tunnel_toggle", "тоннель"], ["@flex_limits_toggle", "лимиты flex"], ["@flex_zones_toggle", "зоны flex"]],
	"build_polygon": [["ЛКМ", "вершина"], ["ЛКМ по первой вершине / @shape_confirm", "замкнуть"], ["@shape_undo", "убрать вершину"], ["ПКМ", "сбросить"], ["@level_up/@level_down", "уровень"], ["Shift+@level_up/@level_down, @level_up_x5/@level_down_x5", "уровень ×5"], ["@depth_up/@depth_down", "толщина (Shift ×5)"]],
	"build_strip": [["ЛКМ", "точка оси"], ["ЛКМ по последней точке / @shape_confirm", "закончить"], ["@width_down и @width_up", "ширина (Shift ×5)"], ["@shape_undo", "убрать точку"], ["ПКМ", "сбросить"], ["@level_up/@level_down", "уровень"], ["Shift+@level_up/@level_down, @level_up_x5/@level_down_x5", "уровень ×5"], ["@depth_up/@depth_down", "толщина (Shift ×5)"]],
	"cut_rect": [["ЛКМ", "угол, второй клик режет"], ["@shape_undo", "отменить рисунок"], ["ПКМ", "сбросить / выйти"], ["@level_up/@level_down", "плоскость (Shift ×5)"], ["@depth_up/@depth_down", "глубина (Shift ×5)"], ["@cut_through", "насквозь"], ["@tool_undo", "отменить вырез"]],
	"cut_polygon": [["ЛКМ", "вершина"], ["ЛКМ по первой вершине / @shape_confirm", "вырезать"], ["@shape_undo", "убрать вершину"], ["ПКМ", "сбросить / выйти"], ["@level_up/@level_down", "плоскость (Shift ×5)"], ["@depth_up/@depth_down", "глубина (Shift ×5)"], ["@cut_through", "насквозь"], ["@tool_undo", "отменить вырез"]],
	"cut_strip": [["ЛКМ", "точка оси"], ["ЛКМ по последней точке / @shape_confirm", "вырезать"], ["@width_down и @width_up", "ширина (Shift ×5)"], ["@shape_undo", "убрать точку"], ["ПКМ", "сбросить / выйти"], ["@level_up/@level_down", "плоскость (Shift ×5)"], ["@depth_up/@depth_down", "глубина (Shift ×5)"], ["@cut_through", "насквозь"], ["@tool_undo", "отменить вырез"]],
	"cut_line": [["ЛКМ", "две точки прямой, третий клик отсекает сторону курсора"], ["@shape_undo", "убрать точку"], ["ПКМ", "сбросить / выйти"], ["@level_up/@level_down", "плоскость (Shift ×5)"], ["@depth_up/@depth_down", "глубина (Shift ×5)"], ["@cut_through", "насквозь"], ["@tool_undo", "отменить вырез"]],
	"cut_bevel": [["ЛКМ", "две точки гребня, третий клик режет скос в сторону курсора"], ["@width_down и @width_up", "ступень (Shift ×5)"], ["@depth_up/@depth_down", "высота скоса, слоёв"], ["@level_up/@level_down", "плоскость (Shift ×5)"], ["@shape_undo", "убрать точку"], ["ПКМ", "сбросить / выйти"], ["@tool_undo", "отменить скос"]],
	"table_place": [["ЛКМ", "поставить секцию"], ["@rotate_left/@rotate_right", "повернуть на 90°"], ["@level_up/@level_down", "высота стола ±5 (Shift ×5)"], ["@tool_undo", "убрать последнюю"], ["ПКМ", "выйти"]],
	"sections/select_none": [["ЛКМ", "выбрать секцию"], ["@level_up/@level_down", "высота стола ±5 (Shift ×5)"], ["Кнопка секции внизу", "поставить новую"]],
	"sections/select_sel": [["@delete", "убрать секцию (последнюю и с объектами на ней нельзя)"], ["@level_up/@level_down", "высота стола ±5 (Shift ×5)"], ["Кнопка секции внизу", "поставить новую"]],
	"sections/select_switch": [["@delete", "убрать секцию"], ["@level_up/@level_down", "высота стола ±5 (Shift ×5)"]],
	# XX claude-coaster C1: подсказки режима «Coaster» (ATTN_27). Без V и Z: дубль и зоны flex работают только в Build
	"coaster/select_none": [["ЛКМ", "выбрать трак или вагон"], ["Рамка", "ЛКМ тащить по пустому месту (Ctrl: поверх объектов)"], ["Категория → объект", "построить новый"]],
	"coaster/select_sel": [["Тащить ЛКМ", "переместить"], ["@delete", "удалить"], ["@wagon_kick_fwd/@wagon_kick_back", "пинок вагона"]],
	"coaster/build": [["ЛКМ", "построить"], ["ПКМ", "отмена"], ["@rotate_left/@rotate_right", "поворот {rot}° (Shift: 5°)"], ["@gesture_rotate", "вращать (Shift: точнее)"], ["@gesture_height", "высота"], ["@level_up/@level_down", "уровень"], ["Shift+@level_up/@level_down, @level_up_x5/@level_down_x5", "уровень ×5"]],
	"water_pour": [["ЛКМ", "налить воду (область видна до клика)"], ["Shift+ЛКМ", "осушить"], ["@level_up/@level_down", "глубина воды (Shift ×5)"], ["@level_up_x5/@level_down_x5", "глубина ±5"], ["@tool_undo", "отменить налив"], ["ПКМ", "выйти"]],
	"plaster": [["ЛКМ", "сгладить весь холм под курсором"], ["Shift+ЛКМ", "только этот лист"], ["Ctrl+ЛКМ", "снять (Shift: только лист)"], ["@width_down и @width_up", "ступень пандуса, ю на слой"], ["@tool_undo", "отменить"], ["ПКМ", "выйти"]],
	"paint": [["ЛКМ", "красить (тянуть)"], ["Ctrl+ЛКМ", "стереть"], ["@width_down и @width_up", "радиус кисти, ю (Shift ×5)"], ["@tool_undo", "отменить мазок"], ["ПКМ", "выйти"]],
	"drag": [["Отпустить ЛКМ", "поставить"], ["ПКМ", "отмена"], ["@rotate_left/@rotate_right", "поворот {rot}° (Shift: 5°)"], ["@gesture_rotate", "вращать (Shift: точнее)"], ["@gesture_height", "высота"], ["@level_up/@level_down", "уровень"], ["Shift+@level_up/@level_down, @level_up_x5/@level_down_x5", "уровень ×5"], ["@reset_transform", "сброс"]],
	"wire": [["ЛКМ по клемме", "начать провод"], ["ЛКМ по столу", "точка излома"], ["ЛКМ по второй клемме", "соединить"], ["ПКМ / @wire_cancel", "отмена, повторно выход"]],
	"wire_started": [["ЛКМ по клемме", "соединить"], ["ЛКМ по столу", "точка излома"], ["ПКМ / @wire_cancel", "отмена провода"]],
	"library": [["Режим в разработке", ""]],
	"observe": [["ЛКМ по вагону", "камера Follow"], ["@bookmark_1-@bookmark_5", "перейти к закладке (пустая: сохранить)"], ["Ctrl+@bookmark_1-@bookmark_5 или Shift+карточка", "перезаписать закладку"], ["@photo_hide_ui", "скрыть UI"], ["@photo_snap", "снимок"]],
	"observe_follow": [["@observe_cancel", "выйти из Follow"], ["ЛКМ по другому вагону", "сменить"], ["СКМ + мышь", "вращать камеру вагона"]],
	"observe_pov": [["@observe_cancel", "выйти из POV"], ["POV ↔", "развернуть камеру"], ["ЛКМ по другому вагону", "перенести камеру"]],
	"observe_orbit": [["@observe_cancel", "выйти из Orbit"], ["Orbit", "ещё раз, чтобы остановить"]],
	"observe_photo": [["@photo_snap", "снимок"], ["@photo_hide_ui или @observe_cancel", "вернуть интерфейс"]],
}

## Управление камерой Gimbal, вторая строка, где камерой управляет игрок
const CAMERA_LINE := [["СКМ", "поворот"], ["ПКМ", "сдвиг"], ["Колесо", "зум"], ["@key_w@key_a@key_s@key_d", "перемещение"]]

var enabled := true
var mode: StringName = &"build"
var tool: StringName = &"SelectTool"
var extra: StringName = &""

var _ctx := {}
var _suspended := false
var _last_text := ""
var _layer: CanvasLayer
var _panel: PanelContainer
var _label: RichTextLabel
var _tween: Tween
var _token_re: RegEx


func _ready() -> void:
	_token_re = RegEx.create_from_string("@([a-z0-9_]+)(?:([/-])@([a-z0-9_]+))?")
	Actions.binding_changed.connect(_on_binding_changed)
	Global.build_options.option_changed.connect(func(_k: StringName) -> void: _on_binding_changed(&""))   # шаг поворота в тексте (U12)
	enabled = bool(Settings.get_value("ui", "hints_enabled", true))
	_build_ui()
	_refresh()


# ==========================================
# ПУБЛИЧНЫЙ API
# ==========================================

func set_enabled(on: bool) -> void:
	if on == enabled:
		return
	enabled = on
	Settings.set_value("ui", "hints_enabled", enabled)
	enabled_changed.emit(enabled)
	_refresh()


func set_mode(m: StringName) -> void:
	mode = m
	_refresh()


func set_tool(tool_name: StringName) -> void:
	tool = tool_name
	_refresh()


func set_context(key: StringName, on: bool) -> void:
	if _ctx.get(key, false) == on:
		return
	_ctx[key] = on
	_refresh()


func set_extra(_name: StringName) -> void:
	if extra == _name:
		return
	extra = _name
	_refresh()


## Временно скрыть (снимок экрана)
func suspend(on: bool) -> void:
	_suspended = on
	_refresh()


# ==========================================
# ВЫБОР ТЕКСТА
# ==========================================

## Ключ данных для текущего состояния
func _context_key() -> String:
	if mode == &"library":
		return "library"
	if mode == &"observe":
		if _ctx.get(&"photo", false):
			return "observe_photo"
		if extra != &"":
			return "observe_" + String(extra)
		return "observe"
	match tool:
		&"DragTool":
			return "drag"
		&"WireTool":   # D4: провода между клеммами (контекст ставит сам инструмент)
			return "wire_started" if _ctx.get(&"wire_started", false) else "wire"
		&"PlasterTool":   # XX claude-terra 13.5 G3: гипсовый бинт
			return "plaster"
		&"PaintTool":   # XX claude-terra 13.13 K2: кисть
			return "paint"
		&"WaterPourTool":   # XX claude-terra 13.4 W3: налить воду
			return "water_pour"
		&"TableTool":   # XX claude-table T2: постановка секций
			return "table_place"
		&"ThermoCutTool":   # XX claude-terra 13.3 S2: терморезак (контекст ставит сам инструмент)
			if _ctx.get(&"cut_polygon", false):
				return "cut_polygon"
			if _ctx.get(&"cut_strip", false):
				return "cut_strip"
			if _ctx.get(&"cut_bevel", false):
				return "cut_bevel"
			return "cut_line" if _ctx.get(&"cut_line", false) else "cut_rect"
		&"BuildTool":
			# XX claude-terra 13.2 B2: рисование полигона листа (контекст ставит BuildTool)
			if _ctx.get(&"strip", false):   # XX claude-terra 13.2 B5: лист-полоса
				return "build_strip"
			return "build_polygon" if _ctx.get(&"polygon", false) else "build"
	if _ctx.get(&"group", false):   # XX claude-switch: группа, выбранная рамкой
		return "select_group"
	if _ctx.get(&"selected", false):
		return "select_switch" if _ctx.get(&"switch", false) else "select_sel"
	return "select_none"


func _lookup(key: String) -> Array:
	return HINTS.get(String(mode) + "/" + key, HINTS.get(key, []))


func _compose() -> String:
	var key := _context_key()
	var items := _lookup(key)
	if items.is_empty():
		return ""
	var text := _format(items)
	# Вторая строка про камеру: когда ею управляет игрок (не Follow, POV, Orbit и не фоторежим)
	var own_camera := key in ["select_none", "select_group", "select_sel", "build", "build_polygon", "build_strip", "cut_rect", "cut_polygon", "cut_strip", "cut_line", "cut_bevel", "water_pour", "table_place", "plaster", "wire", "wire_started", "drag", "observe"]
	if own_camera:
		text += "\n[color=%s]%s[/color]" % [DIM_COLOR, _format(CAMERA_LINE, false)]
	return "[center]" + text + "[/center]"


func _format(items: Array, highlight := true) -> String:
	var parts: Array[String] = []
	for it in items:
		# [ и ] в BBCode экранируются: «[/]» без этого читалось бы как закрывающий тег
		# прямая замена «]» на [rb] портила бы «]» у только что вставленного [lb] (на экране выходило «[ib]/]»): идём через служебные знаки
		var k: String = _keys(it[0]).replace("[", "\u0001").replace("]", "\u0002").replace("\u0001", "[lb]").replace("\u0002", "[rb]")
		var t: String = it[1].replace("{rot}", String.num(Global.build_options.rot_step_deg, 0))
		if highlight:
			parts.append(("[b][color=%s]%s[/color][/b] %s" % [KEY_COLOR, k, t]).strip_edges())
		else:
			parts.append("%s %s" % [k, t])
	return SEPARATOR.join(parts)


# ==========================================
# КЛАВИШИ ИЗ INPUTMAP
# ==========================================

## Подставляет клавиши действий в текст: «@rotate_left» → «Q». Пара «@a/@b» или «@a-@b» склеивает общий модификатор:
## @depth_up/@depth_down → «Ctrl+R/F». Жесты (Shift+ЛКМ, Alt + мышь) тоже токены: «@gesture_rotate» → «Alt + мышь», это справочный текст реестра. Остальная мышь пишется текстом
func _keys(text: String) -> String:
	if not text.contains("@"):
		return text
	var out := ""
	var pos := 0
	for m in _token_re.search_all(text):
		out += text.substr(pos, m.get_start() - pos)
		pos = m.get_end()
		var a := _key_of(m.get_string(1))
		if m.get_string(3) == "":
			out += a
			continue
		var b := _key_of(m.get_string(3))
		var pa := a.rfind("+") + 1
		var pb := b.rfind("+") + 1
		if pa > 0 and a.substr(0, pa) == b.substr(0, pb):
			out += a + m.get_string(2) + b.substr(pb)   # Ctrl+R/F: общий модификатор пишется один раз
		else:
			out += a + m.get_string(2) + b
	return out + text.substr(pos)


func _key_of(action: String) -> String:
	var t: String = Actions.key_text(StringName(action))
	return t if t != "" else "—"


## Клавишу действия переназначили (окно ремапа, U11): перерисовать подсказку
func _on_binding_changed(_id: StringName) -> void:
	_last_text = ""
	_refresh()


# ==========================================
# UI
# ==========================================

func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "HintLayer"
	_layer.layer = 10
	add_child(_layer)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.07, 0.10, 0.78)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_panel.offset_bottom = -BOTTOM_MARGIN
	_layer.add_child(_panel)

	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.custom_minimum_size = Vector2(_label_width(), 0.0)
	_label.add_theme_font_size_override("normal_font_size", 15)
	_label.add_theme_font_size_override("bold_font_size", 15)
	_panel.add_child(_label)
	get_viewport().size_changed.connect(_on_viewport_resized)


func _label_width() -> float:
	var w: float = get_viewport().get_visible_rect().size.x
	return clampf(w - 2.0 * SIDE_RESERVE - 32.0, 320.0, MAX_WIDTH)


func _on_viewport_resized() -> void:
	if _label == null:
		return
	_label.custom_minimum_size.x = _label_width()
	_panel.reset_size()


func _refresh() -> void:
	if _panel == null:
		return
	var text := _compose() if (enabled and not _suspended) else ""
	_panel.visible = text != ""
	if text == "" or text == _last_text:
		_last_text = text
		return
	_last_text = text
	_label.text = text
	_panel.reset_size()   # высота подстраивается под число строк
	if _tween:
		_tween.kill()
	_panel.modulate.a = 0.0
	_tween = create_tween()
	_tween.tween_property(_panel, "modulate:a", 1.0, 0.15)
