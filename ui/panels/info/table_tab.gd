class_name InfoTableTab extends InfoTab

# XX claude-table T4 (новый файл)
###########################
## Блок «Стол» во вкладке «Настройки» (ATTN_23 T4, U5a.4): опоры и высота подмакетника
###########################
## Встроен в InfoSettingsTab (embed), создаётся кодом. Видна у настоящей секции стола (C_TableSection без C_Ghost) в режиме «Секции».
## Опоры: ножки, рама на полу (стол 5–20 u), кронштейны к стене (нужна стена у каждой группы секций).
## Всё меняет LYM; отказ (кронштейны без стены) идёт в подвал вкладки красным и возвращает прежний выбор,
## предупреждение об опорах там же (тип warn).

const SUPPORTS := [LayoutConfig.Support.LEGS, LayoutConfig.Support.PLINTH, LayoutConfig.Support.WALL]

var _info: Label
var _support_option: OptionButton
var _height_spin: SpinBox
var _aisle_spin: SpinBox
## Идёт запись значений в контролы: их сигналы (SpinBox сам правит значение при смене пределов) в LYM не идут
var _syncing := false


func _setup() -> void:
	var box := make_page("Стол")
	block_heading(box, "Стол")
	_info = Label.new()
	box.add_child(_info)
	var lbl := Label.new()
	lbl.text = "Опоры"
	box.add_child(lbl)
	_support_option = OptionButton.new()
	for s in SUPPORTS:
		_support_option.add_item(LYM.support_name(s))
	_support_option.item_selected.connect(_on_support_selected)
	box.add_child(_support_option)
	var row := HBoxContainer.new()
	var row_lbl := Label.new()
	row_lbl.text = "Высота стола, u  "
	row.add_child(row_lbl)
	_height_spin = SpinBox.new()
	_height_spin.step = LYM.HEIGHT_STEP
	_height_spin.rounded = false
	_height_spin.value_changed.connect(_on_height_changed)
	row.add_child(_height_spin)
	box.add_child(row)
	var row2 := HBoxContainer.new()
	var row2_lbl := Label.new()
	row2_lbl.text = "Проход у стен, u  "
	row2_lbl.tooltip_text = "Ножки и рама: ближе этого расстояния к стене секцию не поставить. Кронштейны: с рабочих сторон"
	row2.add_child(row2_lbl)
	_aisle_spin = SpinBox.new()
	_aisle_spin.min_value = 0.0
	_aisle_spin.max_value = 150.0
	_aisle_spin.step = 5.0
	_aisle_spin.value_changed.connect(_on_aisle_changed)
	row2.add_child(_aisle_spin)
	box.add_child(row2)


func can_show(entity: Entity) -> bool:
	return entity != null and not entity.has_comp(C_Ghost) and entity.has_comp(C_TableSection)


func _on_bind() -> void:
	footer_message(&"table_msg", "")
	if can_show(target):   # bind зовут для любой цели: у чужой цели вкладку не трогаем (иначе SpinBox сбросит высоту стола)
		_sync(true)


func refresh() -> void:
	if can_show(target):
		_sync(false)


## Живые значения: размер стола, опоры, высота (их меняют ещё клавиши R/F и загрузка сейва)
func _sync(force: bool) -> void:
	_syncing = true
	var rects := LYM.section_rects()
	var r := LYM.table_rect()
	var area := 0.0
	for x in rects:
		area += x.size.x * x.size.y
	_info.text = "Секций: %d\nГабарит: %d × %d u\nПлощадь: %d u²" % [rects.size(), roundi(r.size.x), roundi(r.size.y), roundi(area)]
	var idx := SUPPORTS.find(LYM.config.support)
	if idx >= 0 and (force or _support_option.selected != idx):
		_support_option.select(idx)
	var range_h := LayoutConfig.height_range(LYM.config.support)
	_height_spin.min_value = range_h.x
	_height_spin.max_value = range_h.y
	set_spin(_height_spin, LYM.config.height)
	set_spin(_aisle_spin, LYM.config.aisle_min)
	footer_message(&"table_warn", LYM.support_warning(), &"warn")
	_syncing = false


func _on_support_selected(index: int) -> void:
	if _syncing:
		return
	footer_message(&"table_msg", LYM.set_support(SUPPORTS[index]), &"bad")
	_sync(true)   # отказ: возвращает прежний выбор


func _on_height_changed(value: float) -> void:
	if _syncing:
		return
	LYM.set_height(value)


func _on_aisle_changed(value: float) -> void:
	if _syncing:
		return
	LYM.set_aisle(value)
