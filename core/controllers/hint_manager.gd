extends Node
# class_name не задаём: это синглтон Hints (autoload)

###########################
##💡 Hints - подсказки игроку: внизу экрана над ToolDock или справа сверху (TDD §16)
############################
## Внизу: одна строка через разделитель, над ToolDock (он сообщает свою высоту: set_bottom_lift). Справа: каждое действие
## в отдельной строке под TopBar (при выбранной группе левее ее панели). Расположение: Settings [ui] hints_position (bottom, right).
## Показывает клавиши для текущего режима и инструмента. Без выбранного объекта подсказок нет.
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
const BOTTOM_MARGIN := 14.0
## Расположение: внизу (над ToolDock) или справа сверху. По умолчанию справа (решение U7a: HintBarTopRight)
const POS_BOTTOM := &"bottom"
const POS_RIGHT := &"right"
## Справа: под TopBar (40) с отступом, отступ от правого края
const RIGHT_TOP := 52.0
const RIGHT_MARGIN := 12.0
## Справа при выбранной группе подсказки стоят левее панели группы (GroupSelectionPanel справа сверху)
const GROUP_PANEL_SHIFT := 250.0
## Внизу: зазор между подсказкой и верхом ToolDock
const DOCK_GAP := 8.0
const MAX_WIDTH := 960.0
## По бокам нижней подсказки не заходим на DC (417) и правую колонку: ширина DC + отступ с каждой стороны.
const SIDE_RESERVE := 429.0
const SEPARATOR := "   ·   "

## Пары [клавиша, действие]. Правила состава (21.11.2026): нет строк про камеру; нет действий мыши без модификаторов
## (ЛКМ, ПКМ, Тащить ЛКМ: очевидны); без выбранного объекта подсказок нет (ключи select_none не заведены). Жесты с Shift,
## Ctrl, Alt остаются; у «ЛКМ / клавиша» остается клавиша
const HINTS := {
	"select_group": [["@gesture_add_select", "добавить / убрать объект"], ["@gesture_marquee_add", "добавить рамкой"], ["@delete", "удалить выбранное"], ["Галки в панели", "какие категории в группе"]],
	"select_sel": [["@gesture_add_select", "добавить к выбору"], ["@duplicate_last", "дубль выбранного"], ["@delete", "удалить"], ["@wagon_kick_fwd/@wagon_kick_back", "пинок вагона (зажать: сильнее)"], ["@tunnel_toggle", "тоннель (трак)"], ["@embankment_toggle", "насыпь (трак)"], ["@flex_zones_toggle", "зоны flex"]],
	"select_switch": [["@gesture_add_select", "добавить к выбору"], ["@duplicate_last", "дубль выбранного"], ["@delete", "удалить"], ["@wagon_kick_fwd/@wagon_kick_back", "пинок вагона (зажать: сильнее)"], ["@tunnel_toggle", "тоннель (трак)"], ["@embankment_toggle", "насыпь (трак)"], ["@flex_zones_toggle", "зоны flex"], ["@switch_throw", "переложить стрелку (дистанционную)"]],
	"operate/select_sel": [["@wagon_kick_fwd/@wagon_kick_back", "пинок вагона (зажать: сильнее)"], ["@delete", "удалить"]],
	"operate/select_switch": [["@wagon_kick_fwd/@wagon_kick_back", "пинок вагона (зажать: сильнее)"], ["@delete", "удалить"], ["@switch_throw", "переложить стрелку (дистанционную)"]],
	"build": [["@rotate_left/@rotate_right", "поворот {rot}° (Shift: 5°)"], ["@gesture_rotate", "вращать (Shift: точнее)"], ["@gesture_height", "высота"], ["@level_up/@level_down", "уровень"], ["Shift+@level_up/@level_down, @level_up_x5/@level_down_x5", "уровень ×5"], ["@duplicate_last", "дубль последнего"], ["@tunnel_toggle", "тоннель"], ["@flex_limits_toggle", "лимиты flex"], ["@flex_zones_toggle", "зоны flex"]],
	"build_polygon": [["@shape_confirm", "замкнуть"], ["@shape_undo", "убрать вершину"], ["@level_up/@level_down", "уровень"], ["Shift+@level_up/@level_down, @level_up_x5/@level_down_x5", "уровень ×5"], ["@depth_up/@depth_down", "толщина (Shift ×5)"]],
	"build_strip": [["@shape_confirm", "закончить"], ["@width_down и @width_up", "ширина (Shift ×5)"], ["@shape_undo", "убрать точку"], ["@level_up/@level_down", "уровень"], ["Shift+@level_up/@level_down, @level_up_x5/@level_down_x5", "уровень ×5"], ["@depth_up/@depth_down", "толщина (Shift ×5)"]],
	"cut_rect": [["@shape_undo", "отменить рисунок"], ["@level_up/@level_down", "плоскость (Shift ×5)"], ["@depth_up/@depth_down", "глубина (Shift ×5)"], ["@cut_through", "насквозь"], ["@tool_undo", "отменить вырез"]],
	"cut_polygon": [["@shape_confirm", "вырезать"], ["@shape_undo", "убрать вершину"], ["@level_up/@level_down", "плоскость (Shift ×5)"], ["@depth_up/@depth_down", "глубина (Shift ×5)"], ["@cut_through", "насквозь"], ["@tool_undo", "отменить вырез"]],
	"cut_strip": [["@shape_confirm", "вырезать"], ["@width_down и @width_up", "ширина (Shift ×5)"], ["@shape_undo", "убрать точку"], ["@level_up/@level_down", "плоскость (Shift ×5)"], ["@depth_up/@depth_down", "глубина (Shift ×5)"], ["@cut_through", "насквозь"], ["@tool_undo", "отменить вырез"]],
	"cut_line": [["@shape_undo", "убрать точку"], ["@level_up/@level_down", "плоскость (Shift ×5)"], ["@depth_up/@depth_down", "глубина (Shift ×5)"], ["@cut_through", "насквозь"], ["@tool_undo", "отменить вырез"]],
	"cut_bevel": [["@width_down и @width_up", "ступень (Shift ×5)"], ["@depth_up/@depth_down", "высота скоса, слоёв"], ["@level_up/@level_down", "плоскость (Shift ×5)"], ["@shape_undo", "убрать точку"], ["@tool_undo", "отменить скос"]],
	"table_place": [["@rotate_left/@rotate_right", "повернуть на 90°"], ["@level_up/@level_down", "высота стола ±5 (Shift ×5)"], ["@tool_undo", "убрать последнюю"]],
	"sections/select_sel": [["@delete", "убрать секцию (последнюю и с объектами на ней нельзя)"], ["@level_up/@level_down", "высота стола ±5 (Shift ×5)"], ["Кнопка секции внизу", "поставить новую"]],
	"sections/select_switch": [["@delete", "убрать секцию"], ["@level_up/@level_down", "высота стола ±5 (Shift ×5)"]],
	# XX claude-coaster C1: подсказки режима «Coaster» (ATTN_27). Без V и Z: дубль и зоны flex работают только в Build
	"coaster/select_sel": [["@delete", "удалить"], ["@wagon_kick_fwd/@wagon_kick_back", "пинок вагона (зажать: сильнее)"]],
	"coaster/build": [["@rotate_left/@rotate_right", "поворот {rot}° (Shift: 5°)"], ["@gesture_rotate", "вращать (Shift: точнее)"], ["@gesture_height", "высота"], ["@level_up/@level_down", "уровень"], ["Shift+@level_up/@level_down, @level_up_x5/@level_down_x5", "уровень ×5"]],
	"field_rect": [["Ctrl+ЛКМ", "снять слой"], ["@shape_undo", "отменить рисунок"], ["@tool_undo", "отменить правку"]],
	"field_polygon": [["@shape_confirm", "положить слой"], ["Ctrl+ЛКМ или Ctrl+@shape_confirm", "снять слой"], ["@shape_undo", "убрать вершину"], ["@tool_undo", "отменить правку"]],
	"field_table": [["Ctrl+ЛКМ", "снять слой со всей столешницы"], ["@tool_undo", "отменить правку"]],
	"relief_brush": [["Ctrl+колесо", "подъём или яма (Shift: до целого слоя)"], ["Alt+колесо", "радиус кисти (или , и .)"], ["@width_down и @width_up", "угол склона (Shift ×5)"], ["@brush_objects", "объекты в зоне: игнорировать, обходить, поднимать"], ["@tool_undo", "отменить правку"]],
	"water_pour": [["Shift+ЛКМ", "осушить"], ["@level_up/@level_down", "глубина воды (Shift ×5)"], ["@level_up_x5/@level_down_x5", "глубина ±5"], ["@tool_undo", "отменить налив"]],
	"plaster": [["Shift+ЛКМ", "только этот лист"], ["Ctrl+ЛКМ", "снять (Shift: только лист)"], ["@width_down и @width_up", "ступень пандуса, ю на слой"], ["@tool_undo", "отменить"]],
	"paint": [["Ctrl+ЛКМ", "стереть"], ["@width_down и @width_up", "радиус кисти, ю (Shift ×5)"], ["@tool_undo", "отменить мазок"]],
	"drag": [["@rotate_left/@rotate_right", "поворот {rot}° (Shift: 5°)"], ["@gesture_rotate", "вращать (Shift: точнее)"], ["@gesture_height", "высота"], ["@level_up/@level_down", "уровень"], ["Shift+@level_up/@level_down, @level_up_x5/@level_down_x5", "уровень ×5"], ["@reset_transform", "сброс"]],
	"wire": [["@wire_cancel", "отмена, повторно выход"]],
	"wire_started": [["@wire_cancel", "отмена провода"]],
	"library": [["Режим в разработке", ""]],
	"observe": [["@bookmark_1-@bookmark_5", "перейти к закладке (пустая: сохранить)"], ["Ctrl+@bookmark_1-@bookmark_5 или Shift+карточка", "перезаписать закладку"], ["@photo_hide_ui", "скрыть UI"], ["@photo_snap", "снимок"]],
	"observe_follow": [["@observe_cancel", "выйти из Follow"]],
	"observe_pov": [["@observe_cancel", "выйти из POV"], ["POV ↔", "развернуть камеру"]],
	"observe_orbit": [["@observe_cancel", "выйти из Orbit"], ["Orbit", "ещё раз, чтобы остановить"]],
	"observe_photo": [["@photo_snap", "снимок"], ["@photo_hide_ui или @observe_cancel", "вернуть интерфейс"]],
}

var enabled := true
## Где стоят подсказки: POS_BOTTOM или POS_RIGHT
var position_mode: StringName = POS_RIGHT
var mode: StringName = &"build"
var tool: StringName = &"SelectTool"
var extra: StringName = &""

var _ctx := {}
var _bottom_lift := 0.0   # высота ToolDock снизу (сообщает ToolDockView)
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
	position_mode = StringName(String(Settings.get_value("ui", "hints_position", String(POS_RIGHT))))
	if position_mode != POS_BOTTOM:
		position_mode = POS_RIGHT
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


## Расположение подсказок: POS_BOTTOM или POS_RIGHT
func set_position_mode(p: StringName) -> void:
	if p != POS_BOTTOM and p != POS_RIGHT:
		return
	if p == position_mode:
		return
	position_mode = p
	Settings.set_value("ui", "hints_position", String(p))
	_last_text = ""
	_apply_layout()
	_refresh()


## Высота ToolDock снизу, выше нее стоят подсказки внизу (0: ряд спрятан). Зовет ToolDockView
func set_bottom_lift(px: float) -> void:
	if is_equal_approx(px, _bottom_lift):
		return
	_bottom_lift = px
	_apply_layout()


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
	if key == &"group":
		_apply_layout()   # справа подсказки сдвигаются левее панели группы
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
		&"BrushTool":   # XX claude-terra 13.14 H2: кисть рельефа
			return "relief_brush"
		&"FieldTool":   # XX claude-terra 13.14 H1b: шпатлёвка (контекст ставит сам инструмент)
			if _ctx.get(&"field_polygon", false):
				return "field_polygon"
			return "field_table" if _ctx.get(&"field_table", false) else "field_rect"
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
	if position_mode == POS_RIGHT:
		return text   # справа: каждое действие в своей строке, по левому краю
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
	return ("\n" if position_mode == POS_RIGHT else SEPARATOR).join(parts)


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
	_apply_layout()


## Якоря и отступы панели по расположению. Внизу: по центру, над ToolDock. Справа: под TopBar у правого края
func _apply_layout() -> void:
	if _panel == null:
		return
	if position_mode == POS_RIGHT:
		_panel.anchor_left = 1.0
		_panel.anchor_right = 1.0
		_panel.anchor_top = 0.0
		_panel.anchor_bottom = 0.0
		var right := RIGHT_MARGIN + (GROUP_PANEL_SHIFT if _ctx.get(&"group", false) else 0.0)
		_panel.offset_right = -right
		_panel.offset_left = -right
		_panel.offset_top = RIGHT_TOP
		_panel.offset_bottom = RIGHT_TOP
		_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		_panel.grow_vertical = Control.GROW_DIRECTION_END
		_label.autowrap_mode = TextServer.AUTOWRAP_OFF   # ширина по самой длинной строке
		_label.custom_minimum_size = Vector2.ZERO
	else:
		_panel.anchor_left = 0.5
		_panel.anchor_right = 0.5
		_panel.anchor_top = 1.0
		_panel.anchor_bottom = 1.0
		_panel.offset_left = 0.0
		_panel.offset_right = 0.0
		_panel.offset_top = 0.0
		# Над ToolDock: его высота и зазор; ряд спрятан (Observe): обычный отступ от низа окна
		_panel.offset_bottom = -((_bottom_lift + DOCK_GAP) if _bottom_lift > 0.0 else BOTTOM_MARGIN)
		_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
		_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_label.custom_minimum_size = Vector2(_label_width(), 0.0)
	_last_text = ""   # вид строк зависит от расположения
	_panel.reset_size()
	_refresh()


func _label_width() -> float:
	var w: float = get_viewport().get_visible_rect().size.x
	return clampf(w - 2.0 * SIDE_RESERVE - 32.0, 320.0, MAX_WIDTH)


func _on_viewport_resized() -> void:
	if _label == null or position_mode == POS_RIGHT:
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
