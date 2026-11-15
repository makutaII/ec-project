class_name InfoMainTab extends InfoTab

###########################
## Вкладка «Общее»: паспорт объекта, для трака радиус, длина, уровень, подъем, уклон
###########################
## Узлы в info_panel.tscn (MainTab). Строки Level, Rise, Slope создаются кодом (XX claude-terra 13.1.7).

var _lvl_label: Label
var _rise_label: Label
var _slope_label: Label
var _style_label: Label


func _setup() -> void:
	var grid := _n("TrackContainer") as GridContainer
	_lvl_label = _add_track_row(grid, "Level: ")
	_rise_label = _add_track_row(grid, "Rise: ")
	_slope_label = _add_track_row(grid, "Slope: ")
	_style_label = _add_track_row(grid, "Style: ")


func _add_track_row(grid: GridContainer, title: String) -> Label:
	var t := Label.new()
	t.text = title
	grid.add_child(t)
	var v := Label.new()
	grid.add_child(v)
	return v


## Живые строки: уровень (низ балласта в слоях над столом), подъем и уклон выбранного трака, призрака или трака в драге.
## Жесткий трак: подъем rise из TrackConfig, длина вдоль уклона. Flex: подъем и уклон из C_FlexShape (максимальный)
func refresh() -> void:
	var path := target.get_comp(C_Path) as C_Path if target else null
	if path == null or not is_instance_valid(path) or not target.is_inside_tree():
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
	var identity = target.get_comp(C_Identity)
	if identity:
		_n("CategoryLabel").text = identity.get_category()
		_n("TagLabel").text =  identity.get_tag()
		_n("HeaderLabel").text = '  ' + identity.get_name_e() 
		_n("HeaderRLabel").text ='node : ' + target.name 
		_n("DescriptionLabel").text = identity.get_description()
		_n("IconRect").texture = identity.get_icon()
		
		match  identity.get_category():
			&'track':
				var _path = target.get_comp(C_Path)
				_n("TrackContainer").show()
				_n("TrainContainer").hide()
				if _path:
					_n("RadiusLabel").text = str(_path.radius) + ' u/sm'
					_n("DegLabel").text = str(_path.deg) + '°'
					_n("LengthLabel").text = str(_path.get_length()) + ' u/sm'
				_style_label.text = _style_text()
				refresh()   # XX claude-terra 13.1.7
			&'terrain':
				_n("TrackContainer").hide()
				_n("TrainContainer").hide()
			&'train':
				_n("TrackContainer").hide()
				_n("TrainContainer").show()
				# Типизированное чтение. Раньше брались поля 'power' и 'maxspeed', которых в WagonConfig нет (всегда дефолт 0.0 и 700.0)
				var wc := identity.object_config as WagonConfig
				if wc:
					var is_loco := target.has_comp(C_Engine)
					_n("MassLabel").text = str(wc.mass)
					_n("PowerLabel").text = str(wc.max_tractive_force) if is_loco else "-"
					_n("MaxSpeedLabel").text = str(wc.max_theoretical_speed) if is_loco else "-"
	else:
		# Если это какой-то системный объект без паспорта
		_n("HeaderLabel").text = "Системный объект"
