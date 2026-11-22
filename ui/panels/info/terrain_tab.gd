class_name InfoTerrainTab extends InfoTab

###########################
## Блок «Лист пенопласта» во вкладке «Вид»: толщина листа и стадия отделки (T7, XX claude-terra, U5a.3)
###########################
## Встроен в InfoVisualTab (embed), создаётся кодом. Виден только у настоящего листа (C_TerrainLayer без C_Ghost).
## Стадия: C_TerrainLayer.FoamStage. Размер, слои и уровни показывает вкладка «Сведения» (info_text).
## Причина отказа в изменении толщины идёт в подвал вкладки.

const STAGE_NAMES := ["Сырой пенопласт", "Шпаклёвка", "Краска", "Трава"]

var _stage_option: OptionButton
# XX claude-terra 13.2 B4: толщина листа
var _levels_spin: SpinBox


func _setup() -> void:
	var box := make_page("Лист")
	var head := Label.new()
	head.text = "Лист пенопласта"
	head.theme_type_variation = &"LabelDim"
	box.add_child(head)
	# XX claude-terra 13.2 B4: толщина листа в слоях (верх растёт, низ на месте)
	var row := HBoxContainer.new()
	var row_lbl := Label.new()
	row_lbl.text = "Толщина, слоёв  "
	row.add_child(row_lbl)
	_levels_spin = SpinBox.new()
	_levels_spin.min_value = 1
	_levels_spin.max_value = C_TerrainLayer.MAX_LEVELS
	_levels_spin.step = 1
	_levels_spin.rounded = true
	_levels_spin.value_changed.connect(_on_levels_changed)
	row.add_child(_levels_spin)
	box.add_child(row)
	var lbl := Label.new()
	lbl.text = "Стадия отделки листа"
	box.add_child(lbl)
	_stage_option = OptionButton.new()
	for n in STAGE_NAMES:
		_stage_option.add_item(n)
	_stage_option.item_selected.connect(_on_stage_selected)
	box.add_child(_stage_option)


func can_show(entity: Entity) -> bool:
	return _layer_of(entity) != null


static func _layer_of(entity: Entity) -> C_TerrainLayer:
	if entity == null or entity.has_comp(C_Ghost):
		return null
	return entity.get_comp(C_TerrainLayer) as C_TerrainLayer


func _get_terrain_layer() -> C_TerrainLayer:
	return _layer_of(target)


## Толщина меняется ручками и инструментами: поле следует за ней, пока в нём не идёт ввод
func refresh() -> void:
	var layer := _get_terrain_layer()
	if layer:
		set_spin(_levels_spin, layer.levels)


func _on_bind() -> void:
	var layer := _get_terrain_layer()
	if layer:
		_stage_option.select(layer.stage)
		footer_message(&"terrain", "")
		_levels_spin.set_value_no_signal(layer.levels)


## Размер в плане, толщина и положение по уровням одной подписью (для вкладки «Сведения»).
## Пустая строка, если у цели нет настоящего листа
static func info_text(entity: Entity) -> String:
	var layer := _layer_of(entity)
	if layer == null:
		return ""
	var T: float = Global.settings.layer_height
	# XX claude-terra 13.2 B1: размер берем из контура листа, а не из TerrainConfig (лист может быть любой формы)
	var contour := entity.get_comp(C_Contour) as C_Contour
	var _size := Vector2.ZERO
	if contour:
		_size = contour.size()
	else:
		var tcfg := TerrainConfig.from_entity(entity)
		_size = tcfg.size if tcfg else Vector2.ZERO
	var base := roundi(layer.base_y() / T)
	var shape_text := ""
	if contour and not contour.is_rect():
		shape_text = "Вершин: %d, площадь: %.0f u²\n" % [contour.points.size(), contour.area()]
	return "Размер: %d × %d u\n%sСлоёв: %d (высота %.1f u)\nНижний уровень: %d, верхний: %d\nВырезов: %d" % [
		roundi(_size.x), roundi(_size.y), shape_text, layer.levels, layer.levels * T, base, base + layer.levels, layer.cuts.size()]


## XX claude-terra 13.2 B4. Толщина из SpinBox: C_TerrainLayer либо принимает, либо пишет причину отказа в "error"
func _on_levels_changed(value: float) -> void:
	var layer := _get_terrain_layer()
	if layer == null:
		return
	var d := {"levels": int(value)}
	target.send_event("on_terrain_levels_set", d)
	footer_message(&"terrain", String(d.get("error", "")), &"bad")
	_levels_spin.set_value_no_signal(layer.levels)   # при отказе вернёт в поле прежнее значение


func _on_stage_selected(index: int) -> void:
	if _get_terrain_layer():
		target.send_event("on_terrain_stage_set", {"stage": index})
