class_name InfoMainTab extends InfoTab

###########################
## Вкладка «Сведения»: паспорт объекта, для трака радиус, длина, уровень, подъем, уклон, стиль,
## а также положение, поворот, «на траке» и сцепки (бывшая вкладка «Положение», U5a.1)
###########################
## Узлы в info_panel.tscn (MainTab). Строки Level, Rise, Slope, Style и блок положения создаются кодом
## (XX claude-terra 13.1.7). Кнопка «Записать состав» и её результат живут в подвале вкладки.
## Спидометр и тюнинг физики вагона убраны (DebugPanel, U14), скорость и центробежная сила из панели ушли совсем.

var _lvl_label: Label
var _rise_label: Label
var _slope_label: Label
var _style_label: Label
## Размер, слои и уровни листа террейна (бывшая вкладка «Материал», U5a.3)
var _terrain_box: Control
var _terrain_label: Label

var _chassis: C_Chassis
var _coupler: C_Coupler
var _pos_label: Label
var _rot_label: Label
var _on_track_label: Label
## Строки «Сцепка спереди / сзади»: пары [подпись, значение] (индекс = торец)
var _coupler_rows: Array = []
var _record_button: Button


func _setup() -> void:
	var grid := _n("TrackContainer") as GridContainer
	_lvl_label = _add_track_row(grid, "Уровень: ")
	_rise_label = _add_track_row(grid, "Подъём: ")
	_slope_label = _add_track_row(grid, "Уклон: ")
	_style_label = _add_track_row(grid, "Стиль: ")
	_build_terrain_label()
	_build_pose_block()


func _setup_footer() -> void:
	_record_button = Button.new()
	_record_button.text = "Записать состав"
	_record_button.tooltip_text = "Сохранить все сцепленные вагоны как кнопку «Составы» в каталоге"
	_record_button.visible = false
	_record_button.pressed.connect(_on_record_pressed)
	footer_add_action(_record_button)


func _add_track_row(grid: GridContainer, title: String) -> Label:
	var t := Label.new()
	t.text = title
	grid.add_child(t)
	var v := Label.new()
	grid.add_child(v)
	return v


## Подпись листа террейна под описанием: скрыта у остальных объектов
func _build_terrain_label() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.visible = false
	control.add_child(margin)
	_terrain_label = Label.new()
	margin.add_child(_terrain_label)
	_terrain_box = margin


## Блок положения под описанием: позиция, поворот, «на траке», сцепки спереди и сзади
func _build_pose_block() -> void:
	control.add_child(HSeparator.new())
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	control.add_child(margin)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	margin.add_child(grid)
	_pos_label = _add_pose_row(grid, "Позиция:")[1]
	_rot_label = _add_pose_row(grid, "Поворот:")[1]
	_on_track_label = _add_pose_row(grid, "На траке:")[1]
	for title in ["Сцепка спереди:", "Сцепка сзади:"]:
		_coupler_rows.append(_add_pose_row(grid, title))


## Добавляет в сетку пару подпись и значение, возвращает [подпись, значение]
func _add_pose_row(grid: GridContainer, title: String) -> Array:
	var caption := Label.new()
	caption.text = title
	grid.add_child(caption)
	var value := Label.new()
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(value)
	return [caption, value]


func components_changed() -> void:
	if target == null:
		return
	_chassis = target.get_comp(C_Chassis) as C_Chassis
	_coupler = target.get_comp(C_Coupler) as C_Coupler


func _on_unbind() -> void:
	_chassis = null
	_coupler = null


## Живые строки: положение и сцепки; для трака еще уровень (низ балласта в слоях над столом), подъем и уклон
## выбранного трака, призрака или трака в драге
func refresh() -> void:
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return
	_refresh_pose()
	_refresh_track()
	_refresh_terrain()


func _refresh_pose() -> void:
	var pos := target.global_position
	var rot := target.rotation_degrees
	_pos_label.text = "(%.2f, %.2f, %.2f)" % [pos.x, pos.y, pos.z]
	_rot_label.text = "(%.2f, %.2f, %.2f)" % [rot.x, rot.y, rot.z]
	_set_on_track()
	_set_couplers()


## «На траке»: да (зеленым) или нет (цвет по умолчанию). У объектов без шасси прочерк
func _set_on_track() -> void:
	if _chassis == null:
		_on_track_label.text = "-"
		_set_lamp(_on_track_label, false)
	elif _chassis.is_on_rails:
		_on_track_label.text = "Да"
		_set_lamp(_on_track_label, true)
	else:
		_on_track_label.text = "Нет"
		_set_lamp(_on_track_label, false)


## Статус сцепки: у объектов без C_Coupler строки скрыты, вечная сцепка выделена цветом.
## Кнопка «Записать состав» в подвале видна, когда сцеплено два вагона и больше
func _set_couplers() -> void:
	var chain_len := _coupler.get_consist().size() if _coupler else 0
	_record_button.visible = chain_len >= 2
	refresh_footer()
	for end in _coupler_rows.size():
		var caption := _coupler_rows[end][0] as Label
		var value := _coupler_rows[end][1] as Label
		caption.visible = _coupler != null
		value.visible = _coupler != null
		if _coupler == null:
			continue
		value.text = _coupler.end_status(end)
		_set_lamp(value, _coupler.is_permanent(end))


## Подсветка «включено» цветом темы (вариация LampOn), иначе обычный цвет
func _set_lamp(label: Label, on: bool) -> void:
	var variation: StringName = &"LampOn" if on else &""
	if label.theme_type_variation != variation:
		label.theme_type_variation = variation


func _on_record_pressed() -> void:
	if target == null:
		return
	var res := ConsistStore.record(target)
	if res["ok"]:
		footer_message(&"record", "Записано: %s" % res["name"], &"ok")
	else:
		footer_message(&"record", "Не записано: %s" % res["error"], &"bad")


func _refresh_terrain() -> void:
	var text := InfoTerrainTab.info_text(target)
	_terrain_box.visible = text != ""
	_terrain_label.text = text


## Уровень, подъем и уклон трака. Жесткий трак: подъем rise из TrackConfig, длина вдоль уклона.
## Flex: подъем и уклон из C_FlexShape (максимальный)
func _refresh_track() -> void:
	var path := target.get_comp(C_Path) as C_Path
	if path == null or not is_instance_valid(path):
		return
	var T: float = Global.settings.layer_height

	# низ балласта: самая низкая точка кривой (у пандуса нижний конец), origin пандуса стоит в середине
	var y_low := target.global_position.y
	var samples := path.ballast_samples(4.0)
	if not samples.is_empty():
		y_low = INF
		for d in samples:
			y_low = minf(y_low, float(d["y"]))
	_lvl_label.text = "%.1f сл. (%.1f ю)" % [y_low / T, y_low]

	var flex := target.get_comp(C_FlexShape) as C_FlexShape
	var rise := path.rise
	var slope_pct := 0.0
	var slope_deg := 0.0
	if flex:
		rise = flex.dy
		slope_pct = flex.grade * 100.0
		slope_deg = rad_to_deg(atan(flex.grade))
		_n("LengthLabel").text = "%.1f u/sm" % flex.length
		_n("RadiusLabel").text = "inf" if is_inf(flex.radius) else "%d u/sm" % roundi(flex.radius)
		_n("DegLabel").text = "-"
	else:
		var L := path.get_length()   # у жесткого трака длина вдоль уклона
		if absf(rise) > 0.0001 and L > absf(rise):
			slope_deg = rad_to_deg(asin(absf(rise) / L))
			slope_pct = absf(rise) / sqrt(L * L - rise * rise) * 100.0
	_rise_label.text = "%+.1f ю" % rise if absf(rise) > 0.0001 else "0"
	_slope_label.text = "%.2f%% (%.1f°)" % [slope_pct, slope_deg] if slope_pct > 0.0 else "0"


## Стиль трака (ATTN_17 §17.13): style_id из набора проекта. Стиль-сцена budget у формы без сцены строится
## запасным стилем, об этом сказано в строке. Стиль, зафиксированный в самом объекте, id в набор не пишет
func _style_text() -> String:
	var vis := target.get_comp(C_StyleVisual) as C_StyleVisual
	if target.style_id != &"":
		var st := TSM.get_style(target.style_id)
		if vis != null and vis.style != null and st != null and st.use_scene:
			return "%s (нет сцены, как %s)" % [target.style_id, vis.style.id]
		return String(target.style_id)
	if vis != null and vis.style != null:
		return "%s (в объекте)" % vis.style.id
	return "-"


func _on_bind() -> void:
	components_changed()
	var identity = target.get_comp(C_Identity)
	if identity:
		_n("CategoryLabel").text = identity.get_category()
		_n("TagLabel").text =  identity.get_tag()
		_n("HeaderLabel").text = '  ' + identity.get_name_e() 
		_n("HeaderRLabel").text = ('node : ' + target.name) if Global.debug_mode else ""   # имя узла только в отладке
		_n("DescriptionLabel").text = identity.get_description()
		_n("IconRect").texture = identity.get_icon()
		
		match  identity.get_category():
			&'track', &'coaster_track':   # XX claude-coaster C3: те же поля формы
				var _path = target.get_comp(C_Path)
				_n("TrackContainer").show()
				_n("TrainContainer").hide()
				if _path:
					_n("RadiusLabel").text = str(_path.radius) + ' u/sm'
					_n("DegLabel").text = str(_path.deg) + '°'
					_n("LengthLabel").text = str(_path.get_length()) + ' u/sm'
				_style_label.text = _style_text()
			&'train', &'coaster_car':   # XX claude-coaster C3: те же поля вагона
				_n("TrackContainer").hide()
				_n("TrainContainer").show()
				# Типизированное чтение. Раньше брались поля 'power' и 'maxspeed', которых в WagonConfig нет (всегда дефолт 0.0 и 700.0)
				var wc := identity.object_config as WagonConfig
				if wc:
					var is_loco := target.has_comp(C_Engine)
					_n("MassLabel").text = str(wc.mass)
					_n("PowerLabel").text = str(wc.max_tractive_force) if is_loco else "-"
					_n("MaxSpeedLabel").text = str(wc.max_theoretical_speed) if is_loco else "-"
			_:   # terrain, table, building, dc_controller и прочее: числа трака и вагона не показываем
				_n("TrackContainer").hide()
				_n("TrainContainer").hide()
	else:
		# Если это какой-то системный объект без паспорта
		_n("HeaderLabel").text = "Системный объект"
		_n("HeaderRLabel").text = ""
		_n("TrackContainer").hide()
		_n("TrainContainer").hide()
	refresh()
