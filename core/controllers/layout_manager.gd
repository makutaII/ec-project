extends Node
# class_name не задаём: это синглтон LYM (autoload), как TGM и PGM
###########################
## 💡 LYM - Системный сервис (autoload). Подмакетник: паспорт (LayoutConfig) и запросы по плите стола.
############################
# XX claude-table T0 (новый файл)
##
## ATTN_23. Плиту стола строят секции-Entity (C_TableSection, T1): ставятся в EntitiesRoot, сохраняются как обычные
## объекты. LYM их не хранит, а находит по группе GROUP (как TGM листы пенопласта), поэтому список всегда свежий.
## Потребители (TGM.table_rect, домен воды) спрашивают LYM и про секции не знают.
## Верх плиты всегда y = 0; ground, трак и опоры знают только про слой ground, не про секции.
## Нет ни одной секции (быстрая загрузка fast_debug или секции ещё не созданы): стол берётся из паспорта комнаты, как в v1.

## ⚡ Подмакетник изменился (секция, высота, опоры, загрузка сейва). Слушают опоры, границы камеры, домен воды
signal layout_changed
## XX claude-wire W3: показана ли плита стола. Скрывает её режим «Монтаж» (WiringView), коллизия плиты остаётся
signal plate_visible_changed(on: bool)
## ⚡ Сообщение игроку по подмакетнику (отказ удалить секцию, высота стола). Показывает SelectTool
signal notice(text: String)

## Группа секций (C_TableSection добавляет в неё свою Entity при готовности)
const GROUP := &"table_section"
## Шаг высоты стола клавишами, u
const HEIGHT_STEP := 5.0
## Стартовая секция новой игры и миграции старых сейвов: 200 x 100 (стол v1)
const START_SECTION := "res://data/table/objects/sec_200x100.tres"

## Паспорт текущего макета. Заменяется целиком только через set_state / reset
var config := LayoutConfig.new()

## XX claude-table T4. Высота стола до входа в режим рамы и высота, которую поставила рама (чтобы вернуть при выходе)
var _height_before_plinth := -1.0
var _plinth_set_height := -1.0


## Настоящие секции стола: без призраков и удаляемых
func get_sections() -> Array[Entity]:
	var res: Array[Entity] = []
	if not is_inside_tree():
		return res
	for n in get_tree().get_nodes_in_group(GROUP):
		var e := n as Entity
		if e == null or not e.is_inside_tree() or e.is_queued_for_deletion() or e.has_comp(C_Ghost):
			continue
		res.append(e)
	return res


## Контур секции в мире (x = X, y = Z). Пусто, если у Entity нет плиты
func section_polygon(e: Entity) -> PackedVector2Array:
	var sec := e.get_comp(C_TableSection) as C_TableSection
	return sec.world_polygon() if sec else PackedVector2Array()


## Лежит ли точка (x, z) на плите хотя бы одной секции. Ребро считается плитой
func contains(x: float, z: float) -> bool:
	var pt := Vector2(x, z)
	for e in get_sections():
		var poly := section_polygon(e)
		if poly.size() >= 3 and (Geometry2D.is_point_in_polygon(pt, poly) or _on_edge(pt, poly)):
			return true
	return false


static func _on_edge(pt: Vector2, poly: PackedVector2Array) -> bool:
	var n := poly.size()
	for i in n:
		if Geometry2D.get_closest_point_to_segment(pt, poly[i], poly[(i + 1) % n]).distance_to(pt) < 0.001:
			return true
	return false


## XX claude-table T2. Почему секцию нельзя убрать; пусто: можно. Последняя секция остаётся. Пока на секции стоят объекты
## (трак, вагон, лист, дом), убрать её нельзя: решение по умолчанию ATTN_23 §23.12, вопрос 3
func removal_block_reason(e: Entity) -> String:
	# XX claude-table T4b: последнюю секцию убрать можно (пустой стол: ни плиты, ни опор, секцию можно поставить заново)
	if config.support == LayoutConfig.Support.WALL:
		# XX claude-table T4: стол, державшийся за стену, не должен оторваться от неё из-за удаления
		var all := section_rects()
		var rest: Array[Rect2] = []
		for o in get_sections():
			if o != e:
				var poly := section_polygon(o)
				if poly.size() >= 3:
					rest.append(C_Contour.bounds_of(poly))
		var cfg := room_config()
		if TableRules.wall_layout_reason(all, cfg) == "" and TableRules.wall_layout_reason(rest, cfg) != "":
			return "Остальные секции потеряют крепление к стене"
	var on := objects_on_section(e)
	if on.is_empty():
		return ""
	var counts := {}
	for o in on:
		var cat := GroupSelection.category_of(o)
		var label: String = GroupSelection.LABELS.get(cat, String(cat) if cat != &"" else "Прочее")
		counts[label] = int(counts.get(label, 0)) + 1
	var parts: Array[String] = []
	for k in counts:
		parts.append("%s %d" % [k, counts[k]])
	return "На секции стоят объекты (%s). Сначала уберите их или перенесите" % ", ".join(parts)


## Объекты, которые останутся без стола, если убрать секцию: любая их точка (начало, контрольные точки пути) лежит на этой секции
## и не лежит ни на одной другой. Секции и призраки не считаются
func objects_on_section(sec: Entity) -> Array[Entity]:
	var res: Array[Entity] = []
	var poly := section_polygon(sec)
	if poly.size() < 3 or not is_inside_tree():
		return res
	var others: Array[PackedVector2Array] = []
	for o in get_sections():
		if o != sec:
			others.append(section_polygon(o))
	var root := sec.get_parent()
	if root == null:
		return res
	for n in root.get_children():
		var e := n as Entity
		if e == null or e == sec or e.is_queued_for_deletion() or e.has_comp(C_Ghost) or e.has_comp(C_TableSection):
			continue
		for p in _probe_points(e):
			if _poly_has(poly, p) and not _any_has(others, p):
				res.append(e)
				break
	return res


static func _poly_has(poly: PackedVector2Array, p: Vector2) -> bool:
	return poly.size() >= 3 and (Geometry2D.is_point_in_polygon(p, poly) or _on_edge(p, poly))


static func _any_has(polys: Array[PackedVector2Array], p: Vector2) -> bool:
	for poly in polys:
		if _poly_has(poly, p):
			return true
	return false


## Начало объекта и контрольные точки пути (как у выбора рамкой), в плане (x = X, y = Z)
static func _probe_points(e: Entity) -> Array[Vector2]:
	# XX claude-wire W0: сущность провода стоит в нуле мира, считаем только его точки излома
	var wire := e.get_comp(C_Wire) as C_Wire
	if wire != null:
		return wire.probe_points()
	var pts: Array[Vector2] = [Vector2(e.global_position.x, e.global_position.z)]
	var path := e.get_comp(C_Path) as C_Path
	if path != null and path.path_node != null:
		for c in path.all_curves():
			var l := c.get_baked_length()
			for f in [0.0, 0.5, 1.0]:
				var w := path.path_node.to_global(c.sample_baked(l * f))
				pts.append(Vector2(w.x, w.z))
	return pts


# XX claude-table T4c: пустой стол
const EMPTY_NOTE := "Нет ни одной секции подмакетника: поставьте секцию в режиме «Секции», пока без неё ничего ставить нельзя"

## Есть ли стол, на котором можно строить: хотя бы одна секция (в fast_debug стол из паспорта комнаты, секций нет)
func has_table() -> bool:
	return Global.fast_debug or not get_sections().is_empty()


## Объединение плит: внешние контуры (дыры не учитываем). Касающиеся секции сливаются в один контур, разрозненные остаются отдельными.
## Секций нет: стол v1 одним прямоугольником
func footprint() -> Array[PackedVector2Array]:
	var polys: Array[PackedVector2Array] = []
	for e in get_sections():
		var poly := section_polygon(e)
		if poly.size() >= 3:
			polys.append(poly)
	var merged: Array[PackedVector2Array] = []
	if polys.is_empty():
		return merged   # XX claude-table T4b: стол пуст (убрали все секции), опор нет
	for poly in polys:
		var cur := poly
		var rest: Array[PackedVector2Array] = []
		for m in merged:
			var outers := _outer_polygons(Geometry2D.merge_polygons(m, cur))
			if outers.size() == 1:
				cur = outers[0]
			else:
				rest.append(m)
		rest.append(cur)
		merged = rest
	return merged


## Из результата merge_polygons только внешние контуры (дыры обходятся по часовой стрелке)
static func _outer_polygons(u: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var res: Array[PackedVector2Array] = []
	for p in u:
		if not Geometry2D.is_polygon_clockwise(p):
			res.append(p)
	return res


## Толщина плиты, u: наибольшая у секций (ножки встают под неё). Секций нет: значение паспорта комнаты
func plate_thickness() -> float:
	var t := 0.0
	for e in get_sections():
		var sec := e.get_comp(C_TableSection) as C_TableSection
		if sec != null:
			t = maxf(t, sec.thickness)
	if t > 0.0:
		return t
	var rb := get_tree().get_first_node_in_group(&"room_root") if is_inside_tree() else null
	if rb != null and rb.get("config") is RoomConfig:
		return (rb.get("config") as RoomConfig).table_top_thickness
	return C_TableSection.DEFAULT_THICKNESS


## Где можно ставить секции: внутренний размер комнаты минус проход aisle_min с каждой стороны (ATTN_23 §23.4).
## Комнаты нет или она &"none" (стенд): без ограничения
func placement_limits() -> Rect2:
	var big := Rect2(-100000.0, -100000.0, 200000.0, 200000.0)
	var rb := get_tree().get_first_node_in_group(&"room_root") if is_inside_tree() else null
	if rb == null or not (rb.get("config") is RoomConfig):
		return big
	var cfg := rb.get("config") as RoomConfig
	if cfg.shape == &"none":
		return big
	var half := Vector2(cfg.size.x, cfg.size.z) * 0.5 - Vector2.ONE * config.aisle_min
	if half.x <= 0.0 or half.y <= 0.0:
		return Rect2()
	return Rect2(-half, half * 2.0)


## XX claude-table T4. Паспорт комнаты, в которой стоит стол; null, если комнаты нет (быстрая загрузка)
func room_config() -> RoomConfig:
	var rb := get_tree().get_first_node_in_group(&"room_root") if is_inside_tree() else null
	if rb != null and rb.get("config") is RoomConfig:
		return rb.get("config") as RoomConfig
	return null


## Ограничивающие прямоугольники настоящих секций
func section_rects() -> Array[Rect2]:
	var res: Array[Rect2] = []
	for e in get_sections():
		var poly := section_polygon(e)
		if poly.size() >= 3:
			res.append(C_Contour.bounds_of(poly))
	return res


## Названия опор для игрока
static func support_name(s: int) -> String:
	match s:
		LayoutConfig.Support.PLINTH:
			return "Рама на полу"
		LayoutConfig.Support.WALL:
			return "Кронштейны к стене"
		_:
			return "Ножки"


## Почему нельзя перейти на эти опоры; пусто: можно. Кронштейнам нужна комната со стенами. Стол, не касающийся стены,
## переход не запрещает: его контуры без стены стоят на ножках, пока секции не придвинут к стене (support_warning)
func support_block_reason(s: int) -> String:
	if s == LayoutConfig.Support.WALL and not TableRules.has_walls(room_config()):
		return "В этой комнате нет стен"
	return ""


## Предупреждение по текущим опорам: что не крепится к стене (стоит на ножках) и слишком ли глубокий стол. Пусто: всё в порядке
func support_warning() -> String:
	if config.support != LayoutConfig.Support.WALL:
		return ""
	var why := TableRules.wall_layout_reason(section_rects(), room_config())
	if why != "":
		return "%s: эта часть стоит на ножках. Придвиньте секцию к стене" % why
	return depth_warning()


## Проход вокруг стола, u (ножки и рама: от стен не ближе; кронштейны: с рабочих сторон)
func set_aisle(v: float) -> void:
	config.aisle_min = clampf(v, 0.0, 150.0)


# XX claude-wire W3: плита стола показана (true) или скрыта (режим «Монтаж»). В сейв не пишется
var plate_visible := true


func set_plate_visible(on: bool) -> void:
	if on == plate_visible:
		return
	plate_visible = on
	plate_visible_changed.emit(on)


# XX claude-wire W2: подрамник под плитой (виден при ножках)
func set_apron(on: bool) -> void:
	if on == config.apron:
		return
	config.apron = on
	layout_changed.emit()


## Сменить опоры. Возвращает причину отказа или пусто. Рама держит только низкий стол (5–20 u): высота подгоняется,
## при возврате на ножки прежняя высота возвращается, если её не меняли
func set_support(s: int) -> String:
	if s == int(config.support):
		return ""
	var why := support_block_reason(s)
	if why != "":
		notice.emit(why)
		return why
	var prev := config.support
	if s == LayoutConfig.Support.PLINTH:
		_height_before_plinth = config.height
		var r := LayoutConfig.height_range(LayoutConfig.Support.PLINTH)
		config.height = LayoutConfig.PLINTH_HEIGHT_DEFAULT if config.height > r.y else clampf(config.height, r.x, r.y)
		_plinth_set_height = config.height
	elif prev == LayoutConfig.Support.PLINTH:
		if _height_before_plinth > 0.0 and is_equal_approx(config.height, _plinth_set_height):
			config.height = _height_before_plinth
		_height_before_plinth = -1.0
	config.support = s as LayoutConfig.Support
	layout_changed.emit()
	var warn := support_warning()
	notice.emit("Опоры: %s, высота стола %d u%s" % [support_name(s).to_lower(), int(config.height), ("\n" + warn) if warn != "" else ""])
	return ""


## Можно ли поставить секцию rect по правилам комнаты, опор и соседей; пусто: можно
func placement_reason(rect: Rect2) -> String:
	var cfg := room_config()
	var why := TableRules.placement_reason(rect, cfg, int(config.support), config.aisle_min)
	if why != "":
		return why
	var rects := section_rects()
	var touches := false
	for r in rects:
		if rect.grow(-TableRules.EPS).intersects(r):
			return "Пересекает другую секцию"
		if TableTool.shares_edge(rect, r):
			touches = true
	if config.support == LayoutConfig.Support.WALL:   # кронштейнам и первая секция нужна стена (или стол, уже стоящий у неё)
		if not touches and TableRules.wall_contacts(rect, cfg).is_empty():
			return "Кронштейнам нужна стена: секция должна касаться стены или стола"
	return ""


## Мягкое предупреждение по стоящим секциям и новой (extra): глубина от стены при кронштейнах. Пусто: нет
func depth_warning(extra: Rect2 = Rect2()) -> String:
	if config.support != LayoutConfig.Support.WALL:
		return ""
	var rects := section_rects()
	if extra.size != Vector2.ZERO:
		rects.append(extra)
	return TableRules.wall_depth_warning(rects, room_config())


## Шаг высоты стола клавишами (режим «Секции»): n шагов по HEIGHT_STEP, игроку сообщается итог
func step_height(n: int) -> void:
	var before := config.height
	set_height(before + float(n) * HEIGHT_STEP)
	var limit := "" if not is_equal_approx(before, config.height) else " (предел)"
	notice.emit("Высота стола %d u%s" % [int(config.height), limit])


## Высота стола: из LayoutConfig, в пределах (T3). Пересборка пола, ножек и границ камеры идёт по layout_changed
func set_height(h: float) -> void:
	var r := LayoutConfig.height_range(config.support)   # XX claude-table T4: у рамы свой предел
	h = clampf(h, r.x, r.y)
	if is_equal_approx(h, config.height):
		return
	config.height = h
	layout_changed.emit()


## Ограничивающий прямоугольник плиты в мире (XZ): объединение секций. Нет секций: стартовая плита v1 из паспорта комнаты
func table_rect() -> Rect2:
	var r := Rect2()
	var any := false
	for e in get_sections():
		var poly := section_polygon(e)
		if poly.size() < 3:
			continue
		var b := C_Contour.bounds_of(poly)
		r = b if not any else r.merge(b)
		any = true
	if any:
		return r
	return _room_table_rect()


## Стол v1 из паспорта комнаты (RoomConfig.table_top), центр в (0, 0)
func _room_table_rect() -> Rect2:
	var size := RoomConfig.new().table_top
	if is_inside_tree():
		var rb := get_tree().get_first_node_in_group(&"room_root")
		if rb != null and rb.get("config") is RoomConfig:
			size = (rb.get("config") as RoomConfig).table_top
	return Rect2(-size * 0.5, size)


## Стартовая секция, если стол пуст: новая игра, сейв до подмакетника, очистка макета (ATTN_23 §23.2, инвариант 5).
## Размер и толщину берёт из паспорта комнаты (RoomConfig.table_top: стол v1 остаётся источником миграции).
## root: куда класть секцию (EntitiesRoot). Возвращает созданную секцию или null (секции уже есть, fast_debug)
func ensure_start_section(root: Node) -> Entity:
	if Global.fast_debug or root == null or not get_sections().is_empty():
		return null
	var setting := load(START_SECTION) as EntitySetting
	if setting == null:
		push_error("LYM: нет стартовой секции %s" % START_SECTION)
		return null
	var factory := EntityFactory.new()
	var e := factory.create_from_setting(setting)
	factory.free()
	var rb := get_tree().get_first_node_in_group(&"room_root")
	if rb != null and rb.get("config") is RoomConfig:
		var cfg := rb.get("config") as RoomConfig
		var contour := e.get_comp(C_Contour) as C_Contour
		if contour != null and contour.size() != cfg.table_top:
			contour.set_rect(cfg.table_top)
		var sec := e.get_comp(C_TableSection) as C_TableSection
		if sec != null:
			sec.thickness = cfg.table_top_thickness
	root.add_child(e)
	return e


## Состояние для SavedGame.layout
func get_state() -> Dictionary:
	return config.get_state()


## Загрузка сейва. Пустой словарь (сейв до подмакетника): значения по умолчанию, стол как в v1
func set_state(d: Dictionary) -> void:
	_height_before_plinth = -1.0
	_plinth_set_height = -1.0
	config = LayoutConfig.new()
	if not d.is_empty():
		config.set_state(d)
	layout_changed.emit()


## Новый макет: всё по умолчанию
func reset() -> void:
	set_plate_visible(true)   # XX claude-wire W3: новая игра начинается с видимой плитой
	set_state({})
