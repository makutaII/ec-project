class_name C_TerrainLayer extends C_Visual

# XX claude-terra (новый файл)
###################################
## Визуал и физика листа пенопласта. Сцены нет: все ноды строятся в коде (как C_FlexVisual).
###################################
## Лист = призма: контур C_Contour в плане на высоту levels * layer_height.
## Origin Entity = низ листа, поэтому лист на столе стоит на y = 0, а лист на листе на его верху.
##  - вырезы (FoamCut, T4): окно, ниша, тоннель. Лист строится блоками слоев: подряд идущие слои
##    с одинаковым набором вырезов склеиваются в один блок (призму). Без вырезов лист один блок;
##  - меш: верх, низ и стенки каждого блока (SurfaceTool), нормали плоские;
##  - коллизия: StaticBody3D на слое ground, полигоны блока раскладываются на выпуклые куски;
##  - призрак (C_Ghost) и драг (C_Drag): тело уезжает на слой ghost, иначе луч драга попадет в сам лист
##    (так же, как у трака в C_Path.on_select_layer). Выбор слой не меняет: выбранный лист остается землей;
##  - событие terrain_changed в TGM: лист поставлен, сдвинут, удален, поменял форму;
##  - T5, траки: магнит верха листа к низу балласта плоского трака (snap_to_tracks) и канава под
##    балласт, если трак стоит внутри высоты листа (автовырезы FoamCut.auto, recompute_auto_cuts).
## T7, стадии материала: FoamStage (RAW, PLASTER, PAINT, GRASS), материалы в TerrainStyle (верх и бок отдельно),
##    set_stage меняет только материалы поверхностей, геометрия не пересобирается.
## Сейв: levels, cuts, stage. Контур сохраняет C_Contour, поза лежит в transform Entity.

## Стадии материала (D7): сырой пенопласт, шпаклевка, краска, трава
enum FoamStage { RAW, PLASTER, PAINT, GRASS }

## Площадь, меньше которой кусок после клиппинга считаем мусором (ю²)
const MIN_PIECE_AREA := 0.0001

## XX claude-terra 13.2 B2. Наибольшая толщина листа в слоях (D7)
const MAX_LEVELS := 16

## Толщина в слоях (GlobalSetting.layer_height). Целое, минимум 1
var levels := 1

## Вырезы (локальные полигоны + диапазон слоев). Менять через add_cut / remove_last_cut / clear_cuts
var cuts: Array[FoamCut] = []

## Текущая стадия материала и стиль (null = встроенный). Менять через set_stage
var stage: int = FoamStage.RAW
var style: TerrainStyle

var mesh_node: MeshInstance3D
var body: StaticBody3D

## Блоки слоев: {"y0": int, "y1": int, "polys": Array[PackedVector2Array]}.
## Слои [y0, y1), полигоны простые (без дыр), обход против часовой, локальные координаты листа
var _blocks: Array[Dictionary] = []
var _recomputing := false   # защита от повторного входа: пересчет канав сам шлет terrain_changed
var _shapes: Array[CollisionShape3D] = []
var _last_aabb := AABB()
var _surf_side := -1   # индексы поверхностей меша (-1 нет)
var _surf_top := -1
var _surf_cut := -1   # XX claude-terra 13.3 S4: грани среза (стенки выреза, дно ниши, потолок тоннеля)


## Базовый C_Visual.on_added инстанцирует сцену; у листа сцены нет
func on_added() -> void:
	instance = Node3D.new()
	instance.name = 'Foam'
	entity.add_child(instance)

	mesh_node = MeshInstance3D.new()
	mesh_node.name = 'Mesh'
	instance.add_child(mesh_node)

	body = StaticBody3D.new()
	body.name = 'Body'
	instance.add_child(body)
	_apply_collision_layers()

	parts = PartRegistry.build(instance)
	_collect_meshes()
	_on_instance_ready()


func on_entity_ready() -> void:
	entity.add_to_group(TGM.GROUP)
	_rebuild()
	update_visual()
	TGM.terrain_changed.connect(_on_terrain_changed)
	# трак мог стоять под местом, куда поставили лист. После загрузки сейва здесь пусто, а канавы
	# вернет load_data
	recompute_auto_cuts()


## Что-то изменилось рядом (поставили, сдвинули или убрали трак): пересчитать канаву под балласт
func _on_terrain_changed(aabb: AABB) -> void:
	if _last_aabb.size == Vector3.ZERO or not aabb.intersects(_last_aabb.grow(0.1)):
		return
	recompute_auto_cuts()


func on_contour_changed(_d: Dictionary) -> void:
	_rebuild()


func on_component_added(type: Script) -> void:
	super(type)
	if type == C_Ghost or type == C_Drag:
		_apply_collision_layers()
	if type == C_Ghost:
		# призрак канавы не показывает: она считается в точке спавна, а не там, где призрак окажется
		var none: Array[FoamCut] = []
		set_auto_cuts(none)


func on_component_removed(type: Script) -> void:
	super(type)
	if type == C_Ghost or type == C_Drag:
		_apply_collision_layers(type)


## Драг начался: лист уходит с места (C_Drag уже висит, get_layers() его не отдаст), землю под ним надо пересчитать
func on_drag_started(_d: Dictionary) -> void:
	_notify()


## Лист окончательно встал (шлет C_TerrainDraggable после проверки перекрытия и возможного возврата
## на исходное место). Не on_drag_ended: порядок компонентов не гарантирует, что откат уже сделан
func on_terrain_moved(_d: Dictionary) -> void:
	recompute_auto_cuts()   # лист встал на новое место: канавы под тракты заново
	_notify()


func _exit_tree() -> void:
	super()
	# лист удален: сообщаем старую область (призрака не учитываем)
	if is_instance_valid(TGM) and _last_aabb.size != Vector3.ZERO and entity and not entity.has_comp(C_Ghost):
		TGM.notify_changed(_last_aabb)


## --- Слои коллизии ---

## removing: тип компонента, который прямо сейчас снимается (has_comp на него еще может отвечать true)
func _apply_collision_layers(removing: Script = null) -> void:
	if body == null:
		return
	var floating := (has_comp(C_Ghost) and removing != C_Ghost) or (has_comp(C_Drag) and removing != C_Drag)
	body.collision_layer = Global.active_layers(['ghost']) if floating else Global.active_layers(['ground'])
	body.collision_mask = 0   # статическое тело само ничего не ищет


## XX claude-terra 13.2 B2. Задать толщину в слоях (1..MAX_LEVELS). Origin остается низом листа, верх растет.
## Пересобирает меш и коллизию; _rebuild сам сообщает terrain_changed
func set_levels(n: int) -> void:
	n = clampi(n, 1, MAX_LEVELS)
	if n == levels:
		return
	levels = n
	_rebuild()


## XX claude-terra 13.2 B4. Событие InfoPanel: задать толщину {"levels": int}. При отказе пишет причину в data["error"]
func on_terrain_levels_set(d: Dictionary) -> void:
	var err := try_set_levels(int(d.get("levels", levels)))
	if err != "":
		d["error"] = err


## Изменить толщину настоящего листа. Утолщение вверх не может налезть на другой лист (D6): тогда отказ.
## Вырезы обрезаются по новой высоте. Возвращает причину отказа или пустую строку
func try_set_levels(n: int) -> String:
	n = clampi(n, 1, MAX_LEVELS)
	if n == levels:
		return ""
	if n > levels and entity and entity.is_inside_tree() and not has_comp(C_Ghost):
		var T: float = Global.settings.layer_height
		var new_top := base_y() + float(n) * T
		if not TGM.layers_overlapping(world_polygon(), top_y(), new_top, entity).is_empty():
			return "Сверху другой лист: нет места"
	levels = n
	_prune_cuts()
	_rebuild()
	return ""


## Вырезы за пределами новой толщины убираем, остальные подрезаем по верху. Автовырезы пересчитает recompute_auto_cuts
func _prune_cuts() -> void:
	var keep: Array[FoamCut] = []
	for c in cuts:
		if not c.auto:
			c.to_level = mini(c.to_level, levels)
			if c.from_level >= c.to_level:
				continue
		keep.append(c)
	cuts = keep


## --- Вырезы ---

## Вырезать полигон (локальные XZ листа) из слоев [from_level, to_level). Слои считаем от низа листа.
## 13.3 S1: возвращает созданный вырез (null: вырезать нечего) - по нему его можно снять через remove_cut
func add_cut(polygon: PackedVector2Array, from_level: int, to_level: int) -> FoamCut:
	if polygon.size() < 3:
		return null
	var lv := maxi(1, levels)
	var c := FoamCut.new()
	c.polygon = polygon
	c.from_level = clampi(from_level, 0, lv)
	c.to_level = clampi(to_level, 0, lv)
	if c.to_level <= c.from_level:
		return null
	cuts.append(c)
	_rebuild()
	return c


## XX claude-terra 13.3 S1. Снять конкретный вырез (откат терморезака). false: такого выреза в листе уже нет
## (лист мог подрезать его при уменьшении толщины)
func remove_cut(c: FoamCut) -> bool:
	var i := cuts.find(c)
	if i < 0:
		return false
	cuts.remove_at(i)
	_rebuild()
	return true


## Убрать последний ручной вырез (автовырезы под траки пересчитываются сами)
func remove_last_cut() -> void:
	for i in range(cuts.size() - 1, -1, -1):
		if not cuts[i].auto:
			cuts.remove_at(i)
			_rebuild()
			return


func clear_cuts() -> void:
	if cuts.is_empty():
		return
	cuts.clear()
	_rebuild()


## --- Траки (T5) ---

## Автовырезы под траки (T5 канава, T6 тоннель). Для каждого настоящего трака, чей балласт заходит
## в высоту листа, лист прорезается по контуру балласта:
##  - обычный трак: канава от низа балласта до верха листа (лист поставили поверх трака);
##  - тоннельный трак (C_Tunnel): проход высотой th + TunnelClearance, над ним остается свод.
## Трак, стоящий на листе (низ у верха листа в пределах underground_tolerance), лист не режет.
## Трак режется по образцам кривой: подряд идущие участки с одинаковым диапазоном слоев дают один вырез,
## поэтому пандус и flex режутся ступенями. Слои режем целиком: если низ балласта не кратен слою,
## под балластом остается зазор не больше слоя
func recompute_auto_cuts() -> void:
	if _recomputing or entity == null or not entity.is_inside_tree() or entity.is_queued_for_deletion():
		return
	if has_comp(C_Ghost) or has_comp(C_Drag):
		return
	_recomputing = true
	var mine := world_polygon()
	var inv := entity.global_transform.affine_inverse()
	var res: Array[FoamCut] = []
	for t in TGM.get_tracks():
		res.append_array(_track_cuts(t.get_comp(C_Path) as C_Path, mine, inv))
	set_auto_cuts(res)
	_recomputing = false


## Вырезы одного трака. mine: контур листа в мире, inv: из мира в локальные координаты листа
func _track_cuts(path: C_Path, mine: PackedVector2Array, inv: Transform3D) -> Array[FoamCut]:
	var res: Array[FoamCut] = []
	var s := path.ballast_samples()
	var n := s.size() - 1
	if n < 1:
		return res
	var T: float = Global.settings.layer_height
	var tol: float = Global.settings.underground_tolerance
	var th: float = Global.settings.get_track_height()
	var clearance: float = Global.settings.tunnel_clearance
	var margin: float = Global.settings.terrain_cut_margin
	var tunnel := path.allows_underground()
	var _body := th + clearance if tunnel else th   # высота, которую занимает трак над низом балласта
	var base := base_y()
	var top := top_y()
	var lv := maxi(1, levels)

	# диапазон слоев для каждого участка между образцами; -1: участок листа не касается
	var from_l: Array[int] = []
	var to_l: Array[int] = []
	for i in n:
		var y0: float = s[i]["y"]
		var y1: float = s[i + 1]["y"]
		var lo := minf(y0, y1)
		var hi := maxf(y0, y1)
		if lo >= top - tol or hi + _body <= base + TGM.EPS:
			from_l.append(-1)
			to_l.append(-1)
			continue
		var f := clampi(floori((lo - base) / T + 0.001), 0, lv - 1)
		var e := lv
		if tunnel:
			e = clampi(ceili((hi + _body - base) / T - 0.001), f + 1, lv)
		from_l.append(f)
		to_l.append(e)

	# подряд идущие участки с одним диапазоном слоев склеиваем в один вырез
	var k := 0
	while k < n:
		if from_l[k] < 0:
			k += 1
			continue
		var j := k
		while j + 1 < n and from_l[j + 1] == from_l[k] and to_l[j + 1] == to_l[k]:
			j += 1
		var poly := PackedVector2Array()
		for q in range(k, j + 2):
			poly.append(_margin_edge(s, q, n, margin, true))
		for q in range(j + 1, k - 1, -1):
			poly.append(_margin_edge(s, q, n, margin, false))
		if TGM.overlap_area(mine, poly) > TGM.MIN_OVERLAP_AREA:
			var local := PackedVector2Array()
			for p in poly:
				var l := inv * Vector3(p.x, 0.0, p.y)
				local.append(Vector2(l.x, l.z))
			var c := FoamCut.new()
			c.polygon = local
			c.from_level = from_l[k]
			c.to_level = to_l[k]
			c.auto = true
			res.append(c)
		k = j + 1
	return res


## 13.2 B8. Край балласта в образце q, сдвинутый наружу на margin (зазор выреза). left: левый край, иначе правый.
## На концах трака вырез ещё и продлевается вдоль оси: торцы тоже не вплотную
func _margin_edge(s: Array, q: int, n: int, margin: float, left: bool) -> Vector2:
	var l: Vector2 = s[q]["l"]
	var r: Vector2 = s[q]["r"]
	var e := l if left else r
	if margin <= 0.0:
		return e
	var across := l - r
	if across.length() < 0.0001:
		return e
	across = across.normalized()
	e += across * margin if left else -across * margin
	if q == 0 or q == n:
		var along := Vector2(-across.y, across.x)   # перпендикуляр к ширине
		var mid: Vector2 = (l + r) * 0.5
		var other: Vector2 = s[1]["l"] if q == 0 else s[n - 1]["l"]
		var om: Vector2 = (other + (s[1]["r"] if q == 0 else s[n - 1]["r"])) * 0.5
		if along.dot(mid - om) < 0.0:
			along = -along
		e += along * margin
	return e


## Заменить автовырезы на new_cuts. Перестроение только если набор изменился
func set_auto_cuts(new_cuts: Array[FoamCut]) -> void:
	if _auto_signature(cuts) == _auto_signature(new_cuts):
		return
	var keep: Array[FoamCut] = []
	for c in cuts:
		if not c.auto:
			keep.append(c)
	keep.append_array(new_cuts)
	cuts = keep
	_rebuild()


## Подпись набора автовырезов: слои и хеш полигона (одинаковые входы дают одинаковый результат)
func _auto_signature(list: Array[FoamCut]) -> String:
	var s := ""
	for c in list:
		if c.auto:
			s += "%d:%d:%d;" % [c.from_level, c.to_level, hash(c.polygon)]
	return s


## Вертикальный магнит (T5). Верх листа встаёт вплотную к низу балласта плоского трака, под которым (или внутри
## которого) лежит лист. Две зоны:
##  - трак чуть НИЖЕ верха листа (не дальше terrain_snap_dy): лист опускается;
##  - трак ВЫШЕ верха листа (не дальше terrain_snap_levels слоёв, 13.2): лист поднимается под него.
## Вторая зона нужна, потому что траки и листы стоят по уровням: между ними 0 или целые слои, и допуск 0,6 один
## никогда не срабатывает. Выбирается ближайший трак. Alt: без магнита.
## y_floor: ниже этой отметки лист опускать нельзя (поверхность под курсором). Вызывает C_TerrainDraggable
func snap_to_tracks(y_floor: float) -> void:
	if Input.is_key_pressed(KEY_ALT):
		return
	var T: float = Global.settings.layer_height
	var dy_down: float = Global.settings.terrain_snap_dy
	var dy_up: float = float(Global.settings.terrain_snap_levels) * T
	var mine := world_polygon()
	var top := top_y()
	var best := INF
	var best_dy := 0.0
	for t in TGM.get_flat_tracks():
		var path := t.get_comp(C_Path) as C_Path
		var d := path.bottom_y() - top
		if d > dy_up + TGM.EPS or d < -dy_down - TGM.EPS or absf(d) >= best:
			continue
		if TGM.overlap_area(mine, path.footprint_world()) <= TGM.MIN_OVERLAP_AREA:
			continue
		best = absf(d)
		best_dy = d
	if best == INF or best_dy == 0.0:
		return
	var new_y := base_y() + best_dy
	if new_y < y_floor - TGM.EPS:
		return
	entity.global_position.y = new_y


## Отладка (Global.debug_mode), выбранный лист. F7: ниша (верхний слой). Shift+F7: окно (все слои).
## Alt+F7: тоннель (нижний слой, полоса поперек листа). Ctrl+F7: убрать последний вырез
func _unhandled_input(event: InputEvent) -> void:
	if not Global.debug_mode or entity == null or not entity.is_inside_tree():
		return
	if has_comp(C_Ghost) or not has_comp(C_Selected):
		return
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo or k.keycode != KEY_F7:
		return
	get_viewport().set_input_as_handled()
	if k.ctrl_pressed:
		remove_last_cut()
		return
	var b := _contour_bounds()
	var c := b.get_center()
	var lv := maxi(1, levels)
	if k.shift_pressed:
		add_cut(_rect(c, b.size * 0.4), 0, lv)
	elif k.alt_pressed:
		add_cut(_rect(c, Vector2(b.size.x + 2.0, 4.0)), 0, 1)
	else:
		add_cut(_rect(c, b.size * 0.4), lv - 1, lv)


func _contour_bounds() -> Rect2:
	var contour := get_comp(C_Contour) as C_Contour
	if contour == null or contour.points.is_empty():
		return Rect2()
	var lo := contour.points[0]
	var hi := contour.points[0]
	for p in contour.points:
		lo = lo.min(p)
		hi = hi.max(p)
	return Rect2(lo, hi - lo)


func _rect(center: Vector2, size: Vector2) -> PackedVector2Array:
	var h := size * 0.5
	return PackedVector2Array([
		center + Vector2(-h.x, -h.y), center + Vector2(h.x, -h.y),
		center + Vector2(h.x, h.y), center + Vector2(-h.x, h.y)])


## --- Построение ---

func _rebuild() -> void:
	if mesh_node == null:
		return
	var contour := get_comp(C_Contour) as C_Contour
	if contour == null or contour.points.size() < 3:
		return
	var pts := contour.normalized_points()

	if Geometry2D.triangulate_polygon(pts).is_empty():
		# XX claude-terra 13.2 B1: называем причину (самопересечение, короткое ребро и т.д.), если проверка её находит
		var why := C_Contour.validate(pts)
		push_warning("[C_TerrainLayer] контур не триангулируется, лист не построен%s" % ((": " + why) if why != "" else " (вырожденный контур)"))
		_blocks.clear()
		mesh_node.mesh = null
		_clear_shapes()
		return

	_blocks = _compute_blocks(pts)
	mesh_node.mesh = _build_mesh()
	_build_collision()
	_notify()
	if entity:   # XX claude-terra 13.2 B3: ручки контура (C_ContourHandle) встают на новые места
		entity.send_event("on_terrain_rebuilt", {})


## Блоки слоев: подряд идущие слои с одним набором вырезов склеиваем в одну призму
func _compute_blocks(pts: PackedVector2Array) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	var lv := maxi(1, levels)
	var start := 0
	var sig := _cut_signature(0)
	for k in range(1, lv + 1):
		var cur := _cut_signature(k) if k < lv else ""
		if k < lv and cur == sig:
			continue
		var polys := _slab_polygons(pts, _cuts_at(start))
		if not polys.is_empty():
			res.append({"y0": start, "y1": k, "polys": polys})
		start = k
		sig = cur
	return res


## Какие вырезы (по номерам) покрывают слой: строка-подпись набора
func _cut_signature(level: int) -> String:
	var s := ""
	for i in cuts.size():
		if cuts[i].covers(level):
			s += str(i) + ","
	return s


func _cuts_at(level: int) -> Array[FoamCut]:
	var res: Array[FoamCut] = []
	for c in cuts:
		if c.covers(level):
			res.append(c)
	return res


## Контур минус вырезы слоя -> простые полигоны (без дыр), обход против часовой.
## Triangulate и decompose Godot дыры не понимают, поэтому контур заранее режется вертикальными полосами
## через центр (по X) каждого выреза: вырез в такой полосе всегда выходит на границу полосы,
## а значит дыры внутри полигона не остается. Полосы стыкуются по общим вершинам
func _slab_polygons(contour: PackedVector2Array, active: Array[FoamCut]) -> Array[PackedVector2Array]:
	var res: Array[PackedVector2Array] = []
	if active.is_empty():
		res.append(contour)
		return res

	var lo := contour[0]
	var hi := contour[0]
	for p in contour:
		lo = lo.min(p)
		hi = hi.max(p)
	var xs: Array[float] = [lo.x, hi.x]
	for c in active:
		if c.polygon.size() < 3:
			continue
		var cl := c.polygon[0]
		var ch := c.polygon[0]
		for p in c.polygon:
			cl = cl.min(p)
			ch = ch.max(p)
		xs.append((cl.x + ch.x) * 0.5)
	xs.sort()

	for i in xs.size() - 1:
		var xa := xs[i]
		var xb := xs[i + 1]
		if xb - xa < 0.001:
			continue
		var band := PackedVector2Array([
			Vector2(xa, lo.y - 1.0), Vector2(xb, lo.y - 1.0),
			Vector2(xb, hi.y + 1.0), Vector2(xa, hi.y + 1.0)])
		var pieces: Array[PackedVector2Array] = []
		for sp: PackedVector2Array in Geometry2D.intersect_polygons(contour, band):
			pieces.append(sp)
		for c in active:
			var next: Array[PackedVector2Array] = []
			for p in pieces:
				for r: PackedVector2Array in Geometry2D.clip_polygons(p, c.polygon):
					next.append(r)
			pieces = next
		res.append_array(_outer_only(pieces))
	return res


## Оставляет внешние контуры (обход против часовой), мусор и дыры отбрасывает.
## Внешние контуры после Clipper имеют одну ориентацию, дыры противоположную. Самый большой по площади
## полигон всегда внешний (дыра лежит строго внутри внешнего), по нему и определяем ориентацию
func _outer_only(polys: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var res: Array[PackedVector2Array] = []
	var ref := 0.0
	var best := 0.0
	for p in polys:
		var a := C_Contour.signed_area(p)
		if absf(a) > best:
			best = absf(a)
			ref = a
	if best < MIN_PIECE_AREA:
		return res
	for p in polys:
		var s := C_Contour.signed_area(p)
		if absf(s) < MIN_PIECE_AREA:
			continue
		if (s > 0.0) != (ref > 0.0):
			push_warning("[C_TerrainLayer] вырез дал дыру внутри листа, она не построена")
			continue
		var q := p.duplicate()
		if s < 0.0:
			q.reverse()
		res.append(q)
	return res


## Меш листа: три поверхности. 0: бока и низ (внешняя оболочка), 1: верх, 2 (13.3 S4): срез, то есть грани, которые
## появились из-за вырезов (стенки внутри контура, дно ниши, потолок тоннеля). Срез красится отдельным материалом
## (пористый пенопласт). Пустая поверхность не создаётся, номера в _surf_side, _surf_top, _surf_cut (-1 нет)
func _build_mesh() -> ArrayMesh:
	if _blocks.is_empty():
		return null
	var T: float = Global.settings.layer_height
	var lv := maxi(1, levels)
	var contour := get_comp(C_Contour) as C_Contour
	var outline := contour.normalized_points() if contour else PackedVector2Array()
	var sts: Array[SurfaceTool] = []
	for _i in 3:
		var sf := SurfaceTool.new()
		sf.begin(Mesh.PRIMITIVE_TRIANGLES)
		sts.append(sf)
	var counts: Array[int] = [0, 0, 0]
	var any := false
	for b in _blocks:
		var y0: float = float(b["y0"]) * T
		var y1: float = float(b["y1"]) * T
		var top_natural: bool = int(b["y1"]) >= lv   # верх листа; иначе верхняя грань блока видна из-за выреза
		var bottom_natural: bool = int(b["y0"]) <= 0
		for poly: PackedVector2Array in b["polys"]:
			var tris := Geometry2D.triangulate_polygon(poly)
			if tris.is_empty():
				continue
			any = true
			_add_prism(sts, counts, outline, poly, tris, y0, y1, top_natural, bottom_natural)
	_surf_side = -1
	_surf_top = -1
	_surf_cut = -1
	if not any:
		return null
	var mesh := ArrayMesh.new()
	for i in 3:
		if counts[i] == 0:
			continue
		sts[i].commit(mesh)
		match i:
			0:
				_surf_side = mesh.get_surface_count() - 1
			1:
				_surf_top = mesh.get_surface_count() - 1
			_:
				_surf_cut = mesh.get_surface_count() - 1
	_apply_stage(mesh)
	return mesh


## Призма: верх (y1), низ (y0) и стенки. poly обходится против часовой (area > 0).
## sts: поверхности (0 бока и низ, 1 верх, 2 срез), counts: сколько треугольников в каждой.
## Верх и низ блока это срез, если они не совпадают с верхом и низом листа. Стенка это срез, если ребро не лежит на внешнем контуре
func _add_prism(sts: Array[SurfaceTool], counts: Array[int], outline: PackedVector2Array, pts: PackedVector2Array,
		tris: PackedInt32Array, y0: float, y1: float, top_natural: bool, bottom_natural: bool) -> void:
	var top_i := 1 if top_natural else 2
	var bottom_i := 0 if bottom_natural else 2
	# верх и низ
	for i in range(0, tris.size(), 3):
		var a := pts[tris[i]]
		var b := pts[tris[i + 1]]
		var c := pts[tris[i + 2]]
		_put(sts, counts, top_i, Vector3(a.x, y1, a.y), Vector3(b.x, y1, b.y), Vector3(c.x, y1, c.y), Vector3.UP)
		_put(sts, counts, bottom_i, Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y), Vector3(c.x, y0, c.y), Vector3.DOWN)

	# стенки. Наружу от ребра d это (d.y, -d.x)
	var n := pts.size()
	for i in n:
		var p0 := pts[i]
		var p1 := pts[(i + 1) % n]
		var d := p1 - p0
		if d.length_squared() < 0.000001:
			continue
		var outward := Vector3(d.y, 0.0, -d.x).normalized()
		var a0 := Vector3(p0.x, y0, p0.y)
		var a1 := Vector3(p1.x, y0, p1.y)
		var b0 := Vector3(p0.x, y1, p0.y)
		var b1 := Vector3(p1.x, y1, p1.y)
		var wi := 0 if (outline.is_empty() or edge_on_outline(p0, p1, outline)) else 2
		_put(sts, counts, wi, a0, a1, b1, outward)
		_put(sts, counts, wi, a0, b1, b0, outward)


## 13.3 S4. Ребро блока лежит на внешнем контуре листа (середина ребра на отрезке контура с допуском 0,01 ю)
static func edge_on_outline(a: Vector2, b: Vector2, outline: PackedVector2Array) -> bool:
	var m := (a + b) * 0.5
	var n := outline.size()
	for i in n:
		if Geometry2D.get_closest_point_to_segment(m, outline[i], outline[(i + 1) % n]).distance_to(m) < 0.01:
			return true
	return false


func _put(sts: Array[SurfaceTool], counts: Array[int], idx: int, a: Vector3, b: Vector3, c: Vector3, nrm: Vector3) -> void:
	_tri(sts[idx], a, b, c, nrm)
	counts[idx] += 1


## Треугольник, лицевая сторона которого смотрит в nrm. Лицевая грань в Godot идет по часовой стрелке:
## при взгляде на лицевую сторону векторное произведение (b-a)x(c-a) смотрит от наблюдателя, то есть против nrm
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, nrm: Vector3) -> void:
	if (b - a).cross(c - a).dot(nrm) > 0.0:
		var t := b
		b = c
		c = t
	st.set_normal(nrm)
	st.add_vertex(a)
	st.set_normal(nrm)
	st.add_vertex(b)
	st.set_normal(nrm)
	st.add_vertex(c)


func _build_collision() -> void:
	_clear_shapes()
	var T: float = Global.settings.layer_height
	for b in _blocks:
		var y0: float = float(b["y0"]) * T
		var y1: float = float(b["y1"]) * T
		for poly: PackedVector2Array in b["polys"]:
			var pieces: Array = Geometry2D.decompose_polygon_in_convex(poly)
			if pieces.is_empty():
				pieces = [poly]   # разбить не вышло: пробуем полигон целиком (если он выпуклый, это сработает)
			for piece: PackedVector2Array in pieces:
				var v := PackedVector3Array()
				for p: Vector2 in piece:
					v.append(Vector3(p.x, y0, p.y))
					v.append(Vector3(p.x, y1, p.y))
				var shape := ConvexPolygonShape3D.new()
				shape.points = v
				var cs := CollisionShape3D.new()
				cs.shape = shape
				body.add_child(cs)
				_shapes.append(cs)


func _clear_shapes() -> void:
	for cs in _shapes:
		if is_instance_valid(cs):
			cs.queue_free()
	_shapes.clear()


## Материалы стадии на поверхности меша. Вызывается после сборки и при смене стадии
func _apply_stage(mesh: ArrayMesh) -> void:
	if mesh == null:
		return
	var st := style if style != null else TerrainStyle.new()
	if _surf_side >= 0 and _surf_side < mesh.get_surface_count():
		mesh.surface_set_material(_surf_side, st.get_side(stage))
	if _surf_top >= 0 and _surf_top < mesh.get_surface_count():
		mesh.surface_set_material(_surf_top, st.get_top(stage))
	if _surf_cut >= 0 and _surf_cut < mesh.get_surface_count():   # 13.3 S4
		mesh.surface_set_material(_surf_cut, st.get_cut(stage))


## Сменить стадию материала (InfoPanel). Геометрия и физика не трогаются
func set_stage(new_stage: int) -> void:
	new_stage = clampi(new_stage, 0, FoamStage.size() - 1)
	if new_stage == stage:
		return
	stage = new_stage
	if mesh_node:
		_apply_stage(mesh_node.mesh as ArrayMesh)
	entity.send_event("on_terrain_stage_changed", {"stage": stage})


func on_terrain_stage_set(d: Dictionary) -> void:
	set_stage(int(d.get("stage", stage)))


## --- Геометрия для запросов TGM ---

## Нижняя отметка листа в мире (origin Entity = низ листа)
func base_y() -> float:
	return entity.global_position.y


## Толщина листа, ю
func height() -> float:
	var T: float = Global.settings.layer_height
	return float(maxi(1, levels)) * T


## Верхняя отметка листа в мире
func top_y() -> float:
	return base_y() + height()


## Контур листа в мире: Vector2(x = X, y = Z), обход против часовой стрелки.
## Без вырезов: это внешняя граница листа
func world_polygon() -> PackedVector2Array:
	var res := PackedVector2Array()
	var contour := get_comp(C_Contour) as C_Contour
	if contour == null:
		return res
	return _to_world(contour.normalized_points(), entity.global_transform)


func _to_world(poly: PackedVector2Array, xf: Transform3D) -> PackedVector2Array:
	var res := PackedVector2Array()
	for p in poly:
		var w := xf * Vector3(p.x, 0.0, p.y)
		res.append(Vector2(w.x, w.z))
	return res


## Сплошные участки листа над точкой pt (мировые x, z): интервалы Vector2(низ, верх) по мировой Y.
## Подряд идущие слои склеены, поэтому верх интервала это настоящая поверхность.
## Окно дает пустой список, ниша и тоннель дают интервал ниже ниши или над тоннелем
func solid_intervals_at(pt: Vector2) -> Array[Vector2]:
	var res: Array[Vector2] = []
	if entity == null or not entity.is_inside_tree():
		return res
	var loc := entity.global_transform.affine_inverse() * Vector3(pt.x, 0.0, pt.y)
	var lp := Vector2(loc.x, loc.z)
	var T: float = Global.settings.layer_height
	var base := base_y()
	for b in _blocks:
		var inside := false
		for poly: PackedVector2Array in b["polys"]:
			if Geometry2D.is_point_in_polygon(lp, poly):
				inside = true
				break
		if not inside:
			continue
		var lo: float = base + float(b["y0"]) * T
		var hi: float = base + float(b["y1"]) * T
		var last := res.size() - 1
		if last >= 0 and absf(res[last].y - lo) < TGM.EPS:
			res[last] = Vector2(res[last].x, hi)
		else:
			res.append(Vector2(lo, hi))
	return res


## Занимает ли лист (с вырезами) ту же область, что polygon (мировой) в диапазоне высот (y_from, y_to)
func overlaps(polygon: PackedVector2Array, y_from: float, y_to: float) -> bool:
	var T: float = Global.settings.layer_height
	var base := base_y()
	var xf := entity.global_transform
	for b in _blocks:
		var lo: float = base + float(b["y0"]) * T
		var hi: float = base + float(b["y1"]) * T
		if lo >= y_to - TGM.EPS or hi <= y_from + TGM.EPS:
			continue
		for poly: PackedVector2Array in b["polys"]:
			if TGM.overlap_area(polygon, _to_world(poly, xf)) > TGM.MIN_OVERLAP_AREA:
				return true
	return false


## Лист не должен занимать то же место, что другой лист (D6): иначе C_Invalid (красный призрак,
## BuildTool не ставит, DragTool откатит). Вызывает C_TerrainDraggable после каждого движения.
## 13.3 S1: если внешняя призма задевает чужой лист, но у листа есть ручные вырезы (бухта, окно, ниша), считаем
## по его настоящим блокам: чужой лист в бухте не делает этот лист красным. Автовырезы не учитываем: у листа в драге
## они остаются от прежнего места
func update_validity() -> void:
	var bad := not TGM.layers_overlapping(world_polygon(), base_y(), top_y(), entity).is_empty()
	if bad and _has_manual_cuts():
		bad = _solid_overlaps_others()
	if bad and not has_comp(C_Invalid):
		entity.add_component(C_Invalid.new())
	elif not bad and has_comp(C_Invalid):
		entity.remove_component(C_Invalid)


func _has_manual_cuts() -> bool:
	for c in cuts:
		if not c.auto:
			return true
	return false


## Занимает ли твёрдое тело листа (контур минус ручные вырезы, по блокам слоёв) место другого листа
func _solid_overlaps_others() -> bool:
	var contour := get_comp(C_Contour) as C_Contour
	if contour == null or entity == null:
		return false
	var T: float = Global.settings.layer_height
	var saved := cuts
	var manual: Array[FoamCut] = []
	for c in cuts:
		if not c.auto:
			manual.append(c)
	cuts = manual
	var blocks := _compute_blocks(contour.normalized_points())
	cuts = saved
	var xf := entity.global_transform
	var base := base_y()
	for b in blocks:
		for poly: PackedVector2Array in b["polys"]:
			if not TGM.layers_overlapping(_to_world(poly, xf), base + float(b["y0"]) * T, base + float(b["y1"]) * T, entity).is_empty():
				return true
	return false


## --- Помощники ---

## Мировая область листа (по четырем сторонам призмы), для terrain_changed
func _world_aabb(pts: PackedVector2Array, h: float) -> AABB:
	var xf := entity.global_transform
	var box := AABB(xf * Vector3(pts[0].x, 0.0, pts[0].y), Vector3.ZERO)
	for p in pts:
		box = box.expand(xf * Vector3(p.x, 0.0, p.y))
		box = box.expand(xf * Vector3(p.x, h, p.y))
	return box


func _notify() -> void:
	if not is_instance_valid(TGM) or entity == null or not entity.is_inside_tree() or entity.has_comp(C_Ghost):
		return
	var contour := get_comp(C_Contour) as C_Contour
	if contour == null or contour.points.size() < 3:
		return
	var h = float(maxi(1, levels)) * Global.settings.layer_height
	# сообщаем и старую область: лист мог сдвинуться, там земля тоже изменилась
	var old := _last_aabb
	_last_aabb = _world_aabb(contour.normalized_points(), h)
	TGM.notify_changed(_last_aabb if old.size == Vector3.ZERO else old.merge(_last_aabb))


## --- Сейв ---
func save_data() -> Dictionary:
	var arr: Array = []
	for c in cuts:
		arr.append(c.to_dict())
	return {"levels": levels, "cuts": arr, "stage": stage}


func load_data(data: Dictionary) -> void:
	levels = maxi(1, int(data.get("levels", levels)))
	stage = clampi(int(data.get("stage", stage)), 0, FoamStage.size() - 1)
	cuts.clear()
	for d in data.get("cuts", []):
		cuts.append(FoamCut.from_dict(d))
	_rebuild()
