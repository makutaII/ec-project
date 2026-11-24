class_name Embankment extends RefCounted

# XX claude-terra 13.2 B6 (новый файл)
#######################
## Автонасыпь. Клавиша B на выбранном траке: под траком и цепочкой за ним из листов-полос пенопласта строится насыпь.
#######################
## Низкий приоритет (ATTN_TDD, пункт 17): игрок и так может класть и подгонять листы сам. Это быстрый черновик.
##  - цепочка: выбранный трак и соседи, стыкованные концами (по геометрии, как сокеты). Стрелки и кроссы цепочку
##    обрывают, ветвление (у конца два кандидата) тоже;
##  - ось: центры образцов балласта (C_Path.ballast_samples), шаг SAMPLE_STEP;
##  - ширина: балласт + плечо embankment_shoulder с каждой стороны (GlobalSetting);
##  - верх насыпи на каждом участке = floor(самый низкий низ балласта / layer_height) слоёв, то есть не выше балласта;
##    на уклоне получаются ступени, участки одной высоты склеиваются в один лист-полосу. Низ насыпи на столе (Y = 0);
##  - выше MAX_LEVELS слоёв насыпь идёт стопкой листов;
##  - лист, который налез бы на чужой лист (D6), пропускается и считается в сообщении. Листы одной насыпи могут
##    слегка перекрываться клином на изломе ступени, это терпим.
## Результат: обычные листы пресета foam_strip (форму потом можно править ручками контура). Сообщение над траком.

const STRIP_PATH := "res://data/terrain/objects/foam_strip.tres"
const SAMPLE_STEP := 4.0
## Концы траков ближе этого по горизонтали считаем одним стыком (диаметр капсулы сокета)
const JOINT_XZ := 1.2
const NOTE_TIME := 3.0


## Построить насыпь под траком и цепочкой за ним, показать итог над траком
static func build(track: Entity, tool: ToolController) -> void:
	var stat := {"made": 0, "skipped": 0, "why": ""}
	var msg := _build(track, tool, stat)
	_say(track, tool, msg, stat["made"] > 0)


static func _build(track: Entity, tool: ToolController, stat: Dictionary) -> String:
	var setting := load(STRIP_PATH) as EntitySetting
	if setting == null:
		return "Нет пресета foam_strip"
	var T: float = Global.settings.layer_height

	# 1. траки с осью. Стрелки и кроссы (несколько маршрутов) не берём. XX claude-car CS1b: цепочка только из своей сети
	# (дорога не продолжается рельсом и наоборот), ширина насыпи по ложу выбранного пути
	var own := track.get_comp(C_Path) as C_Path
	if own == null:
		return "Насыпь строится под обычным траком (не стрелка и не кросс)"
	var net := own.network_id()
	var items := {}
	for t in TGM.get_tracks():
		var p := t.get_comp(C_Path) as C_Path
		if p == null or p.routes.size() > 1 or p.network_id() != net:
			continue
		var pts := _centre_points(p)
		if pts.size() >= 2:
			items[t] = pts
	if not items.has(track):
		return "Насыпь строится под обычным траком (не стрелка и не кросс)"

	# 2. цепочка: от выбранного трака в обе стороны
	var chain: PackedVector3Array = items[track].duplicate()
	var used := {track: true}
	_extend(chain, items, used)
	chain.reverse()
	_extend(chain, items, used)

	# 3. высота насыпи на каждом участке и склейка в полосы
	var runs := _runs(_segment_levels(chain, T))
	if runs.is_empty():
		return "Насыпь не нужна: трак на столе"
	var created: Array[Entity] = []
	for r: Vector3i in runs:
		# не больше MAX_AXIS точек оси в одном листе: длинную полосу режем с общей точкой на стыке
		var idx := r.x
		while idx <= r.y:
			var last := mini(idx + C_PolygonDraw.MAX_AXIS - 2, r.y)
			var axis := PackedVector3Array()
			for q in range(idx, last + 2):
				axis.append(chain[q])
			_make_sheets(axis, r.z, setting, tool, stat, created, own.bed_half_width())
			idx = last + 1

	var text := "Насыпь: листов %d" % stat["made"]
	if stat["skipped"] > 0:
		text += ", пропущено участков %d (%s)" % [stat["skipped"], stat["why"]]
	return text


## Центры балласта вдоль кривой: x, z мировые, y низ балласта
static func _centre_points(p: C_Path) -> PackedVector3Array:
	var res := PackedVector3Array()
	for s in p.ballast_samples(SAMPLE_STEP):
		var l: Vector2 = s["l"]
		var r: Vector2 = s["r"]
		var c := (l + r) * 0.5
		res.append(Vector3(c.x, float(s["y"]), c.y))
	return res


static func _joint(a: Vector3, b: Vector3) -> bool:
	var tol := maxf(float(Global.settings.joint_level_tol), 0.2)
	return Vector2(a.x - b.x, a.z - b.z).length() < JOINT_XZ and absf(a.y - b.y) <= tol


## Дописать к хвосту цепочки соседей по одному, пока у конца ровно один кандидат (нет ветвления)
static func _extend(chain: PackedVector3Array, items: Dictionary, used: Dictionary) -> void:
	while true:
		var tail := chain[chain.size() - 1]
		var hit: Entity = null
		var hit_pts := PackedVector3Array()
		var n := 0
		for t in items:
			if used.has(t):
				continue
			var pts: PackedVector3Array = items[t]
			if _joint(tail, pts[0]):
				hit = t
				hit_pts = pts
				n += 1
			elif _joint(tail, pts[pts.size() - 1]):
				var rev := pts.duplicate()
				rev.reverse()
				hit = t
				hit_pts = rev
				n += 1
		if n != 1:
			return
		used[hit] = true
		for i in range(1, hit_pts.size()):
			chain.append(hit_pts[i])


## Слоёв насыпи под каждым отрезком цепочки: floor(самый низкий низ балласта на отрезке / layer_height), не меньше 0
static func _segment_levels(chain: PackedVector3Array, layer_height: float) -> Array[int]:
	var res: Array[int] = []
	for i in chain.size() - 1:
		var lo := minf(chain[i].y, chain[i + 1].y)
		res.append(maxi(0, floori(lo / layer_height + 0.001)))
	return res


## Участки подряд с одним числом слоёв (> 0): Vector3i(первый отрезок, последний отрезок, слоёв)
static func _runs(levels: Array[int]) -> Array[Vector3i]:
	var res: Array[Vector3i] = []
	var i := 0
	while i < levels.size():
		if levels[i] <= 0:
			i += 1
			continue
		var j := i
		while j + 1 < levels.size() and levels[j + 1] == levels[i]:
			j += 1
		res.append(Vector3i(i, j, levels[i]))
		i = j + 1
	return res


## Лист-полоса (или стопка листов, если слоёв больше MAX_LEVELS) вдоль оси axis на k слоёв от стола
static func _make_sheets(axis3: PackedVector3Array, k: int, setting: EntitySetting, tool: ToolController,
		stat: Dictionary, created: Array[Entity], bed_hw: float = -1.0) -> void:
	var T: float = Global.settings.layer_height
	var axis := PackedVector2Array()
	for p in axis3:
		axis.append(Vector2(p.x, p.z))
	# XX claude-car CS1b: половина ширины ложа пути (bed_half_width); без неё прежняя ширина балласта
	var half_bed: float = bed_hw if bed_hw > 0.0 else Global.settings.track_ballast_segment.size.x * 0.5
	var hw: float = half_bed + float(Global.settings.embankment_shoulder)
	var res := Geometry2D.offset_polyline(axis, hw, Geometry2D.JOIN_MITER, Geometry2D.END_BUTT)
	if res.size() != 1:
		_skip(stat, "петля или дыра")
		return
	var outline := C_Contour.cleaned(res[0])
	var why := C_Contour.validate(outline)
	if why != "":
		_skip(stat, why)
		return

	# чужие листы на пути (свои же, из этой насыпи, не в счёт)
	for e in TGM.layers_overlapping(outline, 0.0, float(k) * T):
		if not created.has(e):
			_skip(stat, "налезает на другой лист")
			return

	# Origin в центр габарита на сетке, локальные точки без хвостов плавающей точки
	var step: float = Global.settings.terrain_grid_step
	var c := C_Contour.bounds_of(outline).get_center()
	var o := Vector2(snappedf(c.x, step), snappedf(c.y, step))
	var local := PackedVector2Array()
	for v in outline:
		local.append(Vector2(snappedf(v.x - o.x, 0.001), snappedf(v.y - o.y, 0.001)))

	var base := 0.0
	var left := k
	while left > 0:
		var n := mini(left, C_TerrainLayer.MAX_LEVELS)
		var e := tool.entity_factory.create_from_setting(setting)
		e.global_transform = Transform3D(Basis.IDENTITY, Vector3(o.x, base, o.y))
		tool.entities_root.add_child(e)
		(e.get_comp(C_Contour) as C_Contour).set_points(local)
		(e.get_comp(C_TerrainLayer) as C_TerrainLayer).set_levels(n)
		created.append(e)
		stat["made"] += 1
		base += float(n) * T
		left -= n


static func _skip(stat: Dictionary, why: String) -> void:
	stat["skipped"] += 1
	if stat["why"] == "":
		stat["why"] = why


## Сообщение над траком на NOTE_TIME секунд
static func _say(track: Entity, tool: ToolController, msg: String, ok: bool) -> void:
	var line := TrackNote.line(track, &"embankment", 5)
	line.text = msg
	line.modulate = Color(0.6, 1.0, 0.6) if ok else Color(1.0, 0.35, 0.35)
	line.position = Vector3(0.0, 9.0, 0.0)
	line.visible = true
	tool.get_tree().create_timer(NOTE_TIME).timeout.connect(func():
		if is_instance_valid(track):
			line.queue_free())
