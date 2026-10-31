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
## Тексты лежат в HINTS ниже: правятся только там. Ключ "режим/контекст" перекрывает общий "контекст".
## Включение сохраняется через Settings ([ui] hints_enabled), кнопка в меню верхней панели.

signal enabled_changed(on: bool)

const KEY_COLOR := "#ffd54a"
const DIM_COLOR := "#9aa4b2"
const BOTTOM_MARGIN := 14.0
const SEPARATOR := "   ·   "

## Пары [клавиша, действие]
const HINTS := {
	"select_none": [["ЛКМ", "выбрать объект"], ["Категория → объект", "построить новый"], ["V", "дубль последнего"]],
	"operate/select_none": [["ЛКМ", "выбрать вагон или локомотив"], ["Тащить ЛКМ", "переместить выбранный"]],
	"select_sel": [["Тащить ЛКМ", "переместить"], ["Del", "удалить"], ["PgUp/PgDn", "пинок вагона"], ["U", "тоннель (трак)"], ["B", "насыпь (трак)"], ["Z", "зоны flex"]],
	"operate/select_sel": [["Ручка на панели", "ЛКМ вращать, ПКМ обнулить"], ["PgUp/PgDn", "пинок вагона"], ["Тащить ЛКМ", "переместить"], ["Del", "удалить"]],
	"build": [["ЛКМ", "построить"], ["ПКМ", "отмена"], ["Q/E", "поворот 45° (Shift: 5°)"], ["R/F", "уровень"], ["Shift+R/F, PgUp/PgDn", "уровень ×5"], ["V", "дубль последнего"], ["U", "тоннель"], ["L", "лимиты flex"], ["Z", "зоны flex"]],
	"build_polygon": [["ЛКМ", "вершина"], ["ЛКМ по первой вершине / Enter", "замкнуть"], ["Backspace", "убрать вершину"], ["ПКМ", "сбросить"], ["R/F", "уровень"], ["Shift+R/F, PgUp/PgDn", "уровень ×5"], ["Ctrl+R/F", "толщина (Shift ×5)"]],
	"build_strip": [["ЛКМ", "точка оси"], ["ЛКМ по последней точке / Enter", "закончить"], ["[ ]", "ширина (Shift ×5)"], ["Backspace", "убрать точку"], ["ПКМ", "сбросить"], ["R/F", "уровень"], ["Shift+R/F, PgUp/PgDn", "уровень ×5"], ["Ctrl+R/F", "толщина (Shift ×5)"]],
	"cut_rect": [["ЛКМ", "угол, второй клик режет"], ["Backspace", "отменить рисунок"], ["ПКМ", "сбросить / выйти"], ["R/F", "плоскость (Shift ×5)"], ["Ctrl+R/F", "глубина (Shift ×5)"], ["End", "насквозь"], ["Ctrl+Z", "отменить вырез"]],
	"cut_polygon": [["ЛКМ", "вершина"], ["ЛКМ по первой вершине / Enter", "вырезать"], ["Backspace", "убрать вершину"], ["ПКМ", "сбросить / выйти"], ["R/F", "плоскость (Shift ×5)"], ["Ctrl+R/F", "глубина (Shift ×5)"], ["End", "насквозь"], ["Ctrl+Z", "отменить вырез"]],
	"cut_strip": [["ЛКМ", "точка оси"], ["ЛКМ по последней точке / Enter", "вырезать"], ["[ ]", "ширина (Shift ×5)"], ["Backspace", "убрать точку"], ["ПКМ", "сбросить / выйти"], ["R/F", "плоскость (Shift ×5)"], ["Ctrl+R/F", "глубина (Shift ×5)"], ["End", "насквозь"], ["Ctrl+Z", "отменить вырез"]],
	"cut_line": [["ЛКМ", "две точки прямой, третий клик отсекает сторону курсора"], ["Backspace", "убрать точку"], ["ПКМ", "сбросить / выйти"], ["R/F", "плоскость (Shift ×5)"], ["Ctrl+R/F", "глубина (Shift ×5)"], ["End", "насквозь"], ["Ctrl+Z", "отменить вырез"]],
	"drag": [["Отпустить ЛКМ", "поставить"], ["ПКМ", "отмена"], ["Q/E", "поворот 45° (Shift: 5°)"], ["R/F", "уровень"], ["Shift+R/F, PgUp/PgDn", "уровень ×5"], ["Home", "сброс"]],
	"library": [["Режим в разработке", ""]],
	"observe": [["ЛКМ по вагону", "камера Follow"], ["1-5", "перейти к закладке (пустая: сохранить)"], ["Ctrl+1-5 или Shift+карточка", "перезаписать закладку"], ["H", "скрыть UI"], ["P", "снимок"]],
	"observe_follow": [["Esc", "выйти из Follow"], ["ЛКМ по другому вагону", "сменить"], ["СКМ + мышь", "вращать камеру вагона"]],
	"observe_pov": [["Esc", "выйти из POV"], ["POV ↔", "развернуть камеру"], ["ЛКМ по другому вагону", "перенести камеру"]],
	"observe_orbit": [["Esc", "выйти из Orbit"], ["Orbit", "ещё раз, чтобы остановить"]],
	"observe_photo": [["P", "снимок"], ["H или Esc", "вернуть интерфейс"]],
}

## Управление камерой Gimbal, вторая строка, где камерой управляет игрок
const CAMERA_LINE := [["СКМ", "поворот"], ["ПКМ", "сдвиг"], ["Колесо", "зум"], ["WASD", "перемещение"]]

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


func _ready() -> void:
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
		&"ThermoCutTool":   # XX claude-terra 13.3 S2: терморезак (контекст ставит сам инструмент)
			if _ctx.get(&"cut_polygon", false):
				return "cut_polygon"
			if _ctx.get(&"cut_strip", false):
				return "cut_strip"
			return "cut_line" if _ctx.get(&"cut_line", false) else "cut_rect"
		&"BuildTool":
			# XX claude-terra 13.2 B2: рисование полигона листа (контекст ставит BuildTool)
			if _ctx.get(&"strip", false):   # XX claude-terra 13.2 B5: лист-полоса
				return "build_strip"
			return "build_polygon" if _ctx.get(&"polygon", false) else "build"
	return "select_sel" if _ctx.get(&"selected", false) else "select_none"


func _lookup(key: String) -> Array:
	return HINTS.get(String(mode) + "/" + key, HINTS.get(key, []))


func _compose() -> String:
	var key := _context_key()
	var items := _lookup(key)
	if items.is_empty():
		return ""
	var text := _format(items)
	# Вторая строка про камеру: когда ею управляет игрок (не Follow, POV, Orbit и не фоторежим)
	var own_camera := key in ["select_none", "select_sel", "build", "build_polygon", "build_strip", "cut_rect", "cut_polygon", "cut_strip", "cut_line", "drag", "observe"]
	if own_camera:
		text += "\n[color=%s]%s[/color]" % [DIM_COLOR, _format(CAMERA_LINE, false)]
	return "[center]" + text + "[/center]"


func _format(items: Array, highlight := true) -> String:
	var parts: Array[String] = []
	for it in items:
		var k: String = it[0]
		var t: String = it[1]
		if highlight:
			parts.append(("[b][color=%s]%s[/color][/b] %s" % [KEY_COLOR, k, t]).strip_edges())
		else:
			parts.append("%s %s" % [k, t])
	return SEPARATOR.join(parts)


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
	sb.set_corner_radius_all(8)
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
	_label.custom_minimum_size = Vector2(960.0, 0.0)
	_label.add_theme_font_size_override("normal_font_size", 15)
	_label.add_theme_font_size_override("bold_font_size", 15)
	_panel.add_child(_label)


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
