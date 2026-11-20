extends Node
# class_name не задаём: это синглтон TGM (autoload), как PGM
###########################
## 💡 TGM - Системный сервис (autoload). Рельеф: реестр листов пенопласта, аналитические запросы
## по полигонам и события об изменениях.
############################
# XX claude-terra (новый файл)
##
## Лист пенопласта = Entity с C_TerrainLayer. Отдельного списка не ведем: лист при готовности
## входит в группу GROUP, а get_layers() отфильтровывает призраков, листы в драге и удаляемые.
## Физические лучи остаются для тулов, опор и вагонов. Аналитика (ниже) нужна там, где ждать
## физический кадр нельзя или луч не подходит: проверка перекрытия листов, снап, тоннели.
## Все высоты мировые (Y), полигоны мировые (Vector2: x = X, y = Z).

## Лист изменился (поставлен, сдвинут, удален, поменял форму). aabb - мировая область изменения.
## Слушают опоры эстакады и все, кому важна земля под ними
signal terrain_changed(aabb: AABB)

const GROUP := &'terrain_layer'
## XX claude-terra 13.4 W4. Водные участки (Entity с C_Water)
const WATER_GROUP := &'water_body'
## water_level_at: воды над точкой нет
const NO_WATER := -INF
## 13.5. Оболочка гипсового бинта (PlasterSkin), один узел на макет
var skin: PlasterSkin
## 13.13 K1. Краска кистей (мировая сетка, общая на макет) и сплэт-текстура для материала оболочки (K3)
var paint := PaintMap.new()
var splat: PaintSplat
## 13.14 H1. Поле высот шпатлёвки: данные, показ (текстуры и шейдер) и коллизия HeightMap по чанкам
var field := TerrainField.new()
var field_view: FieldView
var field_collision: FieldCollision
## Кэш листов для пола поля (собирается перед каждым пакетом вычислений пола)
var _fl_layers: Array[C_TerrainLayer] = []
var _fl_rects: Array[Rect2] = []
## Отпечаток контуров стола: поле обрезается по столу, когда он изменился
var _table_sig := 0

## Допуск по высоте, ю: касание верха одного листа с низом другого не считается пересечением
const EPS := 0.001
## Пересечение меньше этой площади (ю²) считаем касанием по ребру, а не наложением
const MIN_OVERLAP_AREA := 0.01


func _ready() -> void:
	splat = PaintSplat.new()
	splat.map = paint
	add_child(splat)
	skin = PlasterSkin.new()
	skin.paint = paint
	skin.splat = splat
	add_child(skin)
	terrain_changed.connect(_on_terrain_changed_plaster)
	# XX claude-terra 13.14 H1: поле высот
	field.layer_height = float(Global.settings.layer_height)
	field.floor_prepare = Callable(self, "_field_floor_prepare")
	field.floor_fn = Callable(self, "_field_floor_at")
	field_view = FieldView.new()
	add_child(field_view)
	field_view.bind(field)
	field_collision = FieldCollision.new()
	add_child(field_collision)
	field_collision.bind(field)
	terrain_changed.connect(_on_terrain_changed_field)
	_connect_layout.call_deferred()   # LYM стоит в autoload ниже TGM


## XX claude-terra 13.5. Оболочку пересчитываем, если изменилась область под ней (или её ещё нет)
func _on_terrain_changed_plaster(aabb: AABB) -> void:
	if not skin.has_content:
		skin.request()   # дешёво: без листов с smooth > 0 rebuild выходит сразу
		return
	if skin.region.grow(2.0).intersects(Rect2(aabb.position.x, aabb.position.z, aabb.size.x, aabb.size.z), true):
		skin.request()


## Сила или стадия листа с гипсовым бинтом поменялась, или бинт снят
func plaster_dirty() -> void:
	skin.request()


## Живые листы: без призраков, без листов в драге (они на слое ghost и землей не являются)
## и без тех, что уже удаляются
func get_layers() -> Array[Entity]:
	var res: Array[Entity] = []
	if not is_inside_tree():
		return res
	for n in get_tree().get_nodes_in_group(GROUP):
		var e := n as Entity
		if e == null or not e.is_inside_tree() or e.is_queued_for_deletion():
			continue
		if e.has_comp(C_Ghost) or e.has_comp(C_Drag):
			continue
		res.append(e)
	return res


## Вызывает C_TerrainLayer и траки (C_TrackSupport). Сообщает, что земля или трак в этой области изменились
func notify_changed(aabb: AABB) -> void:
	terrain_changed.emit(aabb)


## Все настоящие траки (с C_Path): без призраков, траков в драге и удаляемых.
## Листы режутся под них (C_TerrainLayer.recompute_auto_cuts): канавой или тоннелем
func get_tracks() -> Array[Entity]:
	var res: Array[Entity] = []
	if not is_inside_tree():
		return res
	for n in get_tree().get_nodes_in_group(&"track_socket"):
		var e := n as Entity
		if e == null or not e.is_inside_tree() or e.is_queued_for_deletion():
			continue
		if e.has_comp(C_Ghost) or e.has_comp(C_Drag) or not e.has_comp(C_Path):
			continue
		res.append(e)
	return res


## Плоские горизонтальные траки (C_Path.is_flat), настоящие: без призраков, траков в драге и удаляемых.
## Только они подгоняют под себя листы: см. C_TerrainLayer.snap_to_tracks и recompute_auto_cuts
func get_flat_tracks() -> Array[Entity]:
	var res: Array[Entity] = []
	if not is_inside_tree():
		return res
	for n in get_tree().get_nodes_in_group(&"track_socket"):
		var e := n as Entity
		if e == null or not e.is_inside_tree() or e.is_queued_for_deletion():
			continue
		if e.has_comp(C_Ghost) or e.has_comp(C_Drag):
			continue
		var p := e.get_comp(C_Path) as C_Path
		if p == null or not p.is_flat():
			continue
		res.append(e)
	return res


## XX claude-terra 13.4. Столешница подмакетника в мире (XZ), центр в (0, 0).
## XX claude-table T0: считает LYM (ATTN_23), здесь остаётся для прежних потребителей (домен воды)
func table_rect() -> Rect2:
	return LYM.table_rect()


## Живые водные участки: без призраков и удаляемых
func get_waters() -> Array[C_Water]:
	var res: Array[C_Water] = []
	if not is_inside_tree():
		return res
	for n in get_tree().get_nodes_in_group(WATER_GROUP):
		var e := n as Entity
		if e == null or not e.is_inside_tree() or e.is_queued_for_deletion() or e.has_comp(C_Ghost):
			continue
		var w := e.get_comp(C_Water) as C_Water
		if w != null:
			res.append(w)
	return res


## Высота поверхности воды над точкой (x, z): самая высокая из вод, накрывающих точку. NO_WATER, если воды нет.
## Для плавающих сущностей: y = water_level_at, а при NO_WATER они стоят на surface_y как обычные
func water_level_at(x: float, z: float) -> float:
	var best := NO_WATER
	var pt := Vector2(x, z)
	for w in get_waters():
		if w.has_water_at(pt):
			best = maxf(best, w.surface_y())
	return best


## --- Аналитические запросы ---

## Верх земли под точкой (x, z): самый высокий верх сплошного участка листа (с учетом вырезов),
## не выше y_max. Нет листа - стол (0).
## exclude: лист, который не учитываем (например, тот, что двигаем)
func surface_y(x: float, z: float, y_max: float = INF, exclude: Entity = null) -> float:
	var best := 0.0
	var pt := Vector2(x, z)
	for e in get_layers():
		if e == exclude:
			continue
		var l := e.get_comp(C_TerrainLayer) as C_TerrainLayer
		if l == null:
			continue
		# сплошные участки над точкой с учетом вырезов: окно пропускает, ниша дает дно ниши
		for iv: Vector2 in l.solid_intervals_at(pt):
			var top := iv.y
			if top <= best or top > y_max + EPS:
				continue
			best = top
	return best


## Насколько точка p (мировая) лежит внутри листов: расстояние вниз от верха листа до точки.
## 0 - точка вне листов или на самой поверхности. Нависающие листы и тоннели работают так же,
## как физический луч "сверху вниз", но без задержки на физический кадр
func depth_in_solid(p: Vector3, exclude: Entity = null) -> float:
	var best := 0.0
	var pt := Vector2(p.x, p.z)
	for e in get_layers():
		if e == exclude:
			continue
		var l := e.get_comp(C_TerrainLayer) as C_TerrainLayer
		if l == null:
			continue
		for iv: Vector2 in l.solid_intervals_at(pt):
			if p.y <= iv.x + EPS or p.y >= iv.y:
				continue
			best = maxf(best, iv.y - p.y)
	return best


## Листы, которые занимают ту же область, что polygon в диапазоне высот (y_from, y_to):
## пересекаются и по площади, и по высоте. Касание (верх одного = низ другого, общее ребро) не в счет
func layers_overlapping(polygon: PackedVector2Array, y_from: float, y_to: float, exclude: Entity = null) -> Array[Entity]:
	var res: Array[Entity] = []
	if polygon.size() < 3:
		return res
	for e in get_layers():
		if e == exclude:
			continue
		var l := e.get_comp(C_TerrainLayer) as C_TerrainLayer
		if l == null:
			continue
		if l.base_y() >= y_to - EPS or l.top_y() <= y_from + EPS:
			continue
		# по блокам слоев листа: вырезы (ниша, окно, тоннель) свободны для других листов
		if l.overlaps(polygon, y_from, y_to):
			res.append(e)
	return res


## Площадь пересечения двух полигонов
func overlap_area(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var s := 0.0
	for poly: PackedVector2Array in Geometry2D.intersect_polygons(a, b):
		s += absf(C_Contour.signed_area(poly))
	return s


## --- Отладка (Global.debug_mode) ---

## F7: сверить аналитику с физическим лучом под курсором
func _unhandled_input(event: InputEvent) -> void:
	if not Global.debug_mode:
		return
	if event.is_action_pressed(&"debug_terrain_probe", false, false):
		_debug_print_surface()
	elif event.is_action_pressed(&"debug_field_toggle", false, false):
		_debug_toggle_field()


func _debug_print_surface() -> void:
	var vp := get_viewport()
	var cam := vp.get_camera_3d()
	if cam == null:
		return
	var mp := vp.get_mouse_position()
	var from := cam.project_ray_origin(mp)
	var to := from + cam.project_ray_normal(mp) * 1000.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = Global.active_layers(['ground'])
	var hit := vp.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		print("[TGM] F7: луч по ground ничего не нашел")
		return
	var p: Vector3 = hit.position
	# y_max чуть выше точки попадания: верх листа, на который попал луч, должен пройти фильтр
	var ys := surface_y(p.x, p.z, p.y + 0.01)
	print("[TGM] F7: луч y=%.3f, surface_y=%.3f, разница=%.4f, листов=%d" % [p.y, ys, absf(p.y - ys), get_layers().size()])


# ==========================================
# XX claude-terra 13.14 H1. ПОЛЕ ВЫСОТ ШПАТЛЁВКИ
# ==========================================
# Слой лежит на столе (пол 0) или на листе (пол = верх листа), толщина относительная. Подробнее: terrain_field.gd.
# Здесь связка с листами и столом: пол по узлам, обрезка по столу, укладка и снятие слоя по полигону.

func _connect_layout() -> void:
	LYM.layout_changed.connect(_on_layout_changed_field)


## Сменилась высота стола, секция, стол заново: обрезать слой по столу и подогнать окно показа
func _on_layout_changed_field() -> void:
	if field_view != null:
		field_view.refit()
	if field.is_empty():
		return
	var polys := field_table_polygons()
	var sig := hash(polys)
	if sig == _table_sig:
		return
	_table_sig = sig
	field.clip_to_polygons(polys)


## Лист изменился: пересчитать пол под ним
func _on_terrain_changed_field(aabb: AABB) -> void:
	_field_floor_prepare()   # кэш листов нужен и коллизии соседних узлов (floor_at без чанка)
	if field.is_empty():
		return
	field.refresh_floor(Rect2(aabb.position.x, aabb.position.z, aabb.size.x, aabb.size.z).grow(TerrainField.STEP))


## После отмены правки: слой, который стол уже не держит, снова обрезать (обрезка в историю не пишется)
func field_reclip() -> void:
	_table_sig = 0
	_on_layout_changed_field()


## Данные поля заменили целиком (загрузка сейва): пол и окно показа пересчитать
func field_dirty() -> void:
	_table_sig = 0
	field.layer_height = float(Global.settings.layer_height)
	if field_view != null:
		field_view.refit()
		field_view.rebuild_all()
	var b := field.bounds()
	if b.size.x > 0.0:
		field.refresh_floor(b)
	_on_layout_changed_field()


## Внешние контуры стола (объединение секций) или прямоугольник стола v1, если секций нет
func field_table_polygons() -> Array[PackedVector2Array]:
	var polys := LYM.footprint()
	if polys.is_empty():
		var r: Rect2 = LYM.table_rect()
		polys.append(TerrainField._rect_poly(r))
	return polys


## Положить слой толщиной layers (слоёв) на область poly (мировой XZ) там, где есть стол. erase: снять слой.
## Возвращает число изменённых узлов. Одна правка для отмены (Ctrl+Z)
func field_lay(poly: PackedVector2Array, layers: float, erase := false) -> int:
	field.layer_height = float(Global.settings.layer_height)
	var n := 0
	field.begin_edit()
	for sp in field_table_polygons():
		for part: PackedVector2Array in Geometry2D.intersect_polygons(poly, sp):
			if Geometry2D.is_polygon_clockwise(part):
				continue   # дыра: у прямоугольных секций не бывает
			n += field.erase_polygon(part) if erase else field.lay_polygon(part, layers)
	field.end_edit()
	return n


## Положить (или снять) слой на весь стол
func field_lay_table(layers: float, erase := false) -> int:
	field.layer_height = float(Global.settings.layer_height)
	var n := 0
	field.begin_edit()
	for sp in field_table_polygons():
		n += field.erase_polygon(sp) if erase else field.lay_polygon(sp, layers)
	field.end_edit()
	return n


## Поверхность поля в точке мира: высота и есть ли слой. Вне слоя возвращает NO_FIELD
const NO_FIELD := -INF

func field_surface_y(x: float, z: float) -> float:
	if not field.covered(x, z):
		return NO_FIELD
	return field.sample(x, z)


## Список листов для пола (раз на пакет вычислений)
func _field_floor_prepare() -> void:
	_fl_layers.clear()
	_fl_rects.clear()
	for e in get_layers():
		var l := e.get_comp(C_TerrainLayer) as C_TerrainLayer
		if l == null:
			continue
		_fl_layers.append(l)
		_fl_rects.append(C_Contour.bounds_of(l.world_polygon()).grow(0.01))


## Пол в точке: верх сплошной стопки, поднимающейся от стола. Висящие листы (мосты) пол не поднимают
func _field_floor_at(x: float, z: float) -> float:
	var pt := Vector2(x, z)
	var ivs: Array[Vector2] = []
	for k in _fl_layers.size():
		if not _fl_rects[k].has_point(pt):
			continue
		for iv: Vector2 in _fl_layers[k].solid_intervals_at(pt):
			ivs.append(iv)
	var y := 0.0
	var moved := not ivs.is_empty()
	while moved:
		moved = false
		for iv in ivs:
			if iv.x <= y + EPS and iv.y > y + EPS:
				y = iv.y
				moved = true
	return y


## Ctrl+Shift+F: слой 1 на весь стол, повторно снять всё поле (отладка H1a, вместо инструмента)
func _debug_toggle_field() -> void:
	var t0 := Time.get_ticks_usec()
	if field.is_empty():
		var n := field_lay_table(1.0)
		print("[TGM] поле: слой на весь стол, узлов %d, чанков %d, %.1f мс" % [n, field.chunk_keys().size(), float(Time.get_ticks_usec() - t0) / 1000.0])
	else:
		field.clear()
		print("[TGM] поле: снято")
