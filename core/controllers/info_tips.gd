extends Node
# class_name не задаём: это синглтон InfoTips (autoload)

###########################
## InfoTips. Сообщения инструментов и подсказки у курсора (U20a.1)
###########################
## Заменяет метки Label3D в мире (аудит U20a, ATTN_17). Игровой код не знает узлов UI: говорит сюда,
## по образцу Hints. Источник (owner: инструмент, строка TrackNote, компонент) отдает набор строк
## и снимает его, когда сказать больше нечего:
##
##   InfoTips.show_lines(self, [InfoTips.title("Терморезак · форма"), InfoTips.dim("ур. 3 · глубина 1"),
##           InfoTips.warn("Больше 40 точек оси")])
##   InfoTips.clear(self)
##
## Подсказка одна на экран: показывается набор источника, который менялся последним; когда он снят, показывается
## предыдущий. Повтор того же набора ничего не меняет и не переводит источник наверх (инструмент может звать
## каждый кадр). Подсказка идет за курсором со смещением, у края экрана переворачивается.
## Источник, который освободился без clear, убирается сам.
## Снимок экрана (фоторежим): suspend(true), как у Hints.
##
## Подсказка при наведении (U20a.5): SelectTool каждый кадр сообщает объект под курсором (hover). Показывается только для
## объектов своего режима (категория входит в CatalogMeta.MODE_CATEGORIES текущего режима), после задержки hover_delay
## (по умолчанию 0,2 с) и только если нет сообщения инструмента; пока нажата кнопка мыши (драг, вращение камеры) молчит.
## Сейчас в ней название объекта и имя узла Entity. Включение и задержка в настройках: [ui] hover_tip, hover_tip_delay.

const LAYER := 12   # над Hints (10), под окнами UI (20)
const CURSOR_OFFSET := Vector2(16.0, 20.0)
const EDGE := 8.0
const SECTION := "ui"
const KEY_HOVER := "hover_tip"
const KEY_HOVER_DELAY := "hover_tip_delay"
const HOVER_DELAY_DEFAULT := 0.2

## Подсказка при наведении включена
var hover_enabled := true
## Задержка перед подсказкой при наведении, с
var hover_delay := HOVER_DELAY_DEFAULT

var _layer: CanvasLayer
var _tip: InfoToolTip
var _entries: Dictionary = {}   # instance_id источника -> {"lines": Array, "sig": String, "stamp": int}
var _stamp := 0
var _suspended := false
var _hover_target: Node
var _hover_t := 0.0


func _ready() -> void:
	hover_enabled = bool(Settings.get_value(SECTION, KEY_HOVER, true))
	hover_delay = float(Settings.get_value(SECTION, KEY_HOVER_DELAY, HOVER_DELAY_DEFAULT))
	_layer = CanvasLayer.new()
	_layer.name = "InfoTipLayer"
	_layer.layer = LAYER
	add_child(_layer)
	_tip = InfoToolTip.new()
	_layer.add_child(_tip)
	set_process(false)


# ==========================================
# СТРОКИ
# ==========================================

func title(text: String) -> InfoToolTip.Line:
	return InfoToolTip.Line.new(text, InfoToolTip.Kind.TITLE)


func info(text: String) -> InfoToolTip.Line:
	return InfoToolTip.Line.new(text, InfoToolTip.Kind.INFO)


func dim(text: String) -> InfoToolTip.Line:
	return InfoToolTip.Line.new(text, InfoToolTip.Kind.DIM)


func ok(text: String) -> InfoToolTip.Line:
	return InfoToolTip.Line.new(text, InfoToolTip.Kind.OK)


func warn(text: String) -> InfoToolTip.Line:
	return InfoToolTip.Line.new(text, InfoToolTip.Kind.WARN)


func danger(text: String) -> InfoToolTip.Line:
	return InfoToolTip.Line.new(text, InfoToolTip.Kind.DANGER)


func line(text: String, kind: int) -> InfoToolTip.Line:
	return InfoToolTip.Line.new(text, kind)


# ==========================================
# ПУБЛИЧНЫЙ API
# ==========================================

## Набор строк источника. Пустой набор то же, что clear
func show_lines(owner: Object, lines: Array) -> void:
	if owner == null:
		return
	if lines.is_empty():
		clear(owner)
		return
	var id := owner.get_instance_id()
	var sig := _signature(lines)
	var entry: Dictionary = _entries.get(id, {})
	if entry.is_empty() or entry["sig"] != sig:
		_stamp += 1
		_entries[id] = {"lines": lines, "sig": sig, "stamp": _stamp}
	set_process(true)


## Снять набор источника (инструмент вышел, курсор ушел со стола, строки кончились)
func clear(owner: Object) -> void:
	if owner == null:
		return
	_entries.erase(owner.get_instance_id())


## Объект под курсором (SelectTool зовет каждый кадр); null: курсор ушел. Тот же объект подряд ничего не меняет
func hover(target: Node) -> void:
	if target == _hover_target:
		return
	_hover_target = target
	_hover_t = 0.0
	if target != null:
		set_process(true)


func set_hover_enabled(on: bool) -> void:
	hover_enabled = on
	Settings.set_value(SECTION, KEY_HOVER, on)


## Задержка перед подсказкой при наведении, с (0: сразу)
func set_hover_delay(sec: float) -> void:
	hover_delay = maxf(sec, 0.0)
	Settings.set_value(SECTION, KEY_HOVER_DELAY, hover_delay)


## Временно скрыть (снимок экрана)
func suspend(on: bool) -> void:
	_suspended = on
	if on and _tip != null:
		_tip.fade(false)


# ==========================================
# ПОКАЗ
# ==========================================

func _process(delta: float) -> void:
	for id: int in _entries.keys():
		if not is_instance_id_valid(id):
			_entries.erase(id)
	var best: Dictionary = {}
	for entry: Dictionary in _entries.values():
		if best.is_empty() or int(entry["stamp"]) > int(best["stamp"]):
			best = entry
	var lines: Array = best["lines"] if not best.is_empty() else _hover_lines(delta)
	if lines.is_empty() or _suspended:
		_tip.fade(false)
		if best.is_empty() and _hover_target == null:
			set_process(false)
		return
	_tip.set_lines(lines)
	_place_at_cursor()
	_tip.fade(true)


## Строки подсказки при наведении, когда задержка прошла; пусто, если показывать нечего
func _hover_lines(delta: float) -> Array:
	if not hover_enabled or _hover_target == null:
		return []
	if not is_instance_valid(_hover_target):
		_hover_target = null
		return []
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) \
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		_hover_t = 0.0   # тащат объект или вращают камеру: после отпускания задержка заново
		return []
	var entity := _hover_target as Entity
	if entity == null:
		return []
	var identity := entity.get_comp(C_Identity) as C_Identity
	if identity == null:
		return []
	var own: Array = CatalogMeta.MODE_CATEGORIES.get(Global.current_mode, [])
	if not own.has(identity.get_category()):
		return []   # объект не этого режима (вагон в Operate, трак в Observe): подсказки нет
	_hover_t += delta
	if _hover_t < hover_delay:
		return []
	return [title(identity.get_name_e()), dim(String(entity.name))]


func _place_at_cursor() -> void:
	var vp := get_viewport()
	var mouse := vp.get_mouse_position()
	var area := vp.get_visible_rect().size
	var s := _tip.size
	var pos := mouse + CURSOR_OFFSET
	if pos.x + s.x > area.x - EDGE:
		pos.x = mouse.x - CURSOR_OFFSET.x - s.x
	if pos.y + s.y > area.y - EDGE:
		pos.y = mouse.y - CURSOR_OFFSET.y - s.y
	pos.x = clampf(pos.x, EDGE, maxf(EDGE, area.x - s.x - EDGE))
	pos.y = clampf(pos.y, EDGE, maxf(EDGE, area.y - s.y - EDGE))
	_tip.position = pos


func _signature(lines: Array) -> String:
	var parts: PackedStringArray = []
	for l: InfoToolTip.Line in lines:
		parts.append("%d|%s" % [l.kind, l.text])
	return "\n".join(parts)
