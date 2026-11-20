class_name InfoToolTip extends PanelContainer

###########################
## InfoToolTip. Сообщение инструмента и подсказка у курсора (U20a.1)
###########################
## Только вид. До MAX_LINES строк: название (16), параметры (14) и статус со знаком ● ! ×.
## Что показывать и где решает сервис InfoTips (autoload): игровой код про этот виджет знает только вид
## строки (InfoToolTip.Line), узлов UI не касается.
## Цвета это набор превью, не из темы (§17.6.10): подсказка лежит над разными фонами мира и должна читаться в обеих темах.
## Класс панели сводки по группе раньше назывался так же, теперь GroupSelectionPanel.

enum Kind { TITLE, INFO, DIM, OK, WARN, DANGER }

const MAX_LINES := 6
const MIN_WIDTH := 200.0
const MAX_WIDTH := 320.0
const FADE_SEC := 0.12
const PAD_X := 10.0
const PAD_Y := 8.0
const BG := Color(0.05, 0.07, 0.10, 0.85)
const COLORS := {
	Kind.TITLE: Color(0.96, 0.97, 1.0),
	Kind.INFO: Color(0.86, 0.89, 0.93),
	Kind.DIM: Color(0.62, 0.67, 0.74),
	Kind.OK: Color(0.45, 1.0, 0.65),
	Kind.WARN: Color(1.0, 0.85, 0.3),
	Kind.DANGER: Color(1.0, 0.4, 0.4),
}
## Знак статуса перед текстом строки: ● норма, ! предупреждение, × отказ
const SIGNS := {
	Kind.OK: "● ",
	Kind.WARN: "! ",
	Kind.DANGER: "× ",
}


## Строка подсказки: текст и вид (Kind). Создает InfoTips.title/info/dim/ok/warn/danger
class Line extends RefCounted:
	var text := ""
	var kind: int = InfoToolTip.Kind.INFO

	func _init(t: String = "", k: int = InfoToolTip.Kind.INFO) -> void:
		text = t
		kind = k


var _box: VBoxContainer
var _labels: Array[Label] = []
var _tween: Tween
var _want := false
var _signature := ""


func _init() -> void:
	name = "InfoToolTip"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(MIN_WIDTH, 0.0)
	visible = false
	modulate.a = 0.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG
	sb.set_corner_radius_all(4)
	sb.content_margin_left = PAD_X
	sb.content_margin_right = PAD_X
	sb.content_margin_top = PAD_Y
	sb.content_margin_bottom = PAD_Y
	add_theme_stylebox_override("panel", sb)
	_box = VBoxContainer.new()
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_theme_constant_override("separation", 2)
	add_child(_box)


## Показать строки (Line). То же самое второй раз не перестраивается
func set_lines(lines: Array) -> void:
	var n := mini(lines.size(), MAX_LINES)
	var sig := _make_signature(lines, n)
	if sig == _signature:
		return
	_signature = sig
	while _labels.size() < n:
		_add_label()
	var widest := 0.0
	for i in _labels.size():
		var label := _labels[i]
		if i >= n:
			label.visible = false
			continue
		var line: Line = lines[i]
		var text: String = String(SIGNS.get(line.kind, "")) + line.text
		var font_size := 16 if line.kind == Kind.TITLE else 14
		label.text = text
		label.visible = true
		label.add_theme_font_size_override("font_size", font_size)
		label.add_theme_color_override("font_color", COLORS.get(line.kind, COLORS[Kind.INFO]))
		var font := label.get_theme_font("font")
		if font != null:
			widest = maxf(widest, font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x)
	custom_minimum_size.x = clampf(widest + 2.0 * PAD_X + 2.0, MIN_WIDTH, MAX_WIDTH)
	reset_size()


## Плавно показать или спрятать (120 мс). Положение задает вызывающий до показа
func fade(on: bool) -> void:
	if on == _want:
		return
	_want = on
	if _tween != null:
		_tween.kill()
	_tween = create_tween()
	if on:
		visible = true
		_tween.tween_property(self, "modulate:a", 1.0, FADE_SEC)
	else:
		_tween.tween_property(self, "modulate:a", 0.0, FADE_SEC)
		_tween.tween_callback(_hide_done)


func _hide_done() -> void:
	if not _want:
		visible = false
		_signature = ""


func _add_label() -> void:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_box.add_child(label)
	_labels.append(label)


func _make_signature(lines: Array, n: int) -> String:
	var parts: PackedStringArray = []
	for i in n:
		var line: Line = lines[i]
		parts.append("%d|%s" % [line.kind, line.text])
	return "\n".join(parts)
