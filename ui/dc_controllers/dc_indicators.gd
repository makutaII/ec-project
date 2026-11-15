class_name DCIndicators extends PanelContainer

########################
## Индикаторы пульта (ATTN_10 D3): лампы «Сеть», «Перегрузка», «КЗ», полоса тока, «Сброс», кнопка «Сеть»
########################
## Сцена `dc_indicators.tscn` (дизайн `ui/templates/dc_indicators_template.tscn`, U15). Вешается над панелью. Читает PowerSource панели,
## обновляется по сигналам PGM (шаг решателя 10 Гц, события защиты, загрузка). Состояние не только цветом:
## у каждой лампы есть слово, у включенной знак ●, у выключенной ○. Цвета ламп и полосы тока из темы
## (LampOn, LampWarn, LampBad, LampOff, ProgressBarWarn, ProgressBarBad), шрифты тоже (LabelSmall).

const SCENE := preload("res://ui/dc_controllers/dc_indicators.tscn")

var source: PowerSource

@onready var _model: Label = %ModelLabel
@onready var _lamp_mains: Label = %LampMains
@onready var _lamp_over: Label = %LampOver
@onready var _lamp_short: Label = %LampShort
@onready var _bar: ProgressBar = %CurrentBar
@onready var _bar_label: Label = %BarLabel
@onready var _mains_btn: CheckButton = %MainsButton
@onready var _reset_btn: Button = %ResetButton


static func create() -> DCIndicators:
	return SCENE.instantiate() as DCIndicators


## Вызывать после add_child (узлы сцены берутся по %)
func setup(src: PowerSource, panel_width: float) -> void:
	source = src
	custom_minimum_size = Vector2(panel_width, 0)
	mouse_filter = Control.MOUSE_FILTER_PASS
	_mains_btn.toggled.connect(_on_mains_toggled)
	_reset_btn.pressed.connect(_on_reset_pressed)

	PGM.solver_stepped.connect(refresh)
	PGM.output_event.connect(_on_output_event)
	PGM.power_updated.connect(_on_power_updated)
	PGM.state_loaded.connect(refresh)
	PGM.state_reset.connect(refresh)
	refresh()


func _on_output_event(_label: int, _kind: String, _reason: String) -> void:
	refresh()


func _on_power_updated(_label: int, _voltage: float) -> void:
	refresh()


## Выводы, по которым показываем ток: выбранный на пульте, при «все» это самый нагруженный
func shown_output() -> PowerOutput:
	if source == null or source.outputs.is_empty():
		return null
	if source.selected > 0:
		var o := source.output_by_label(source.selected)
		if o != null:
			return o
	var best: PowerOutput = source.outputs[0]
	for o in source.outputs:
		if o.current > best.current:
			best = o
	return best


func refresh() -> void:
	if source == null or not is_instance_valid(_model):
		return
	var md := source.data()
	_model.text = "%s · лимит %.1f А" % [String(md.name), float(md.i_max)]

	var needs := source.needs_supply()
	var net_ok: bool = (not needs) or PGM.mains.on
	_set_lamp(_lamp_mains, "Сеть", net_ok, &"LampOn")
	if not net_ok:
		_lamp_mains.theme_type_variation = &"LampBad"   # сеть выключена: красный, знак ○ и слово остаются

	var over := false
	var short := false
	var any_tripped := false
	for o in source.outputs:
		if o.tripped:
			any_tripped = true
			if o.trip_reason == "overload":
				over = true
			else:
				short = true
		elif o.state == PowerOutput.State.OVERLOAD:
			over = true
	_set_lamp(_lamp_over, "Перегрузка", over, &"LampWarn" if not any_tripped else &"LampBad")
	_set_lamp(_lamp_short, "КЗ", short, &"LampBad")
	# Полоса тока: обычная, при перегрузке жёлтая, при срабатывании защиты красная (из темы)
	_bar.theme_type_variation = &"ProgressBarBad" if any_tripped else (&"ProgressBarWarn" if over else &"")

	var out := shown_output()
	if out != null:
		_bar.max_value = out.i_max * 2.0
		_bar.value = out.current
		var total := 0.0
		for o in source.outputs:
			total += o.current
		var txt := "Вывод %d: %.2f А из %.1f А" % [out.label, out.current, out.i_max]
		if source.outputs.size() > 1:
			txt += "\nВсего по источнику: %.2f А" % total
		if source.needs_supply():
			txt += "\nСеть: %.1f Вт из %.0f Вт" % [PGM.mains.load_w, PGM.mains.capacity_w]
			if PGM.mains.overloaded:
				txt += " · перегрузка сети"
		if out.state != PowerOutput.State.OK:
			txt += "\nСостояние: " + out.state_text()
		_bar_label.text = txt
	_mains_btn.visible = needs
	_mains_btn.set_pressed_no_signal(PGM.mains.on)
	_reset_btn.disabled = not any_tripped


## Лампа: слово, знак ● или ○ и тип темы (цвет), выключенная всегда LampOff
func _set_lamp(l: Label, text: String, on: bool, lit_type: StringName) -> void:
	l.text = ("● " if on else "○ ") + text
	l.theme_type_variation = lit_type if on else &"LampOff"


func _on_mains_toggled(on: bool) -> void:
	PGM.set_mains(on)


func _on_reset_pressed() -> void:
	PGM.reset_protection(source)
