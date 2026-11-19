class_name TrackStyleValidator extends RefCounted

########################
## Проверка TrackStyle (ATTN_20, шаг T0)
########################
## Чистые функции без нод и файлов: пользуются Track Studio, позже менеджер стилей и (возможно)
## редактор кастомизации игрока. Ошибка (ERROR) = стиль сломает геометрию или контракт трака,
## предупреждение (WARN) = скорее всего не то, что хотели, справка (INFO) = к сведению.

enum Level { INFO, WARN, ERROR }

const TOL := 0.02                 # допуск положения меша шпалы, ю
const COLLISION_TOL := 0.05       # допуск collision_width против ширины основания, ю
const SLEEPER_TRIS_WARN := 300    # шпал сотни на трак (ATTN_15 §2.9): тяжёлая шпала дорого стоит
const DEFAULT_HEAD_BALLAST := 0.85
const DEFAULT_HEAD_PLAIN := 0.45


## Можно ли строить меш: без этого SurfaceTool получит пустую геометрию
static func can_build(style: TrackStyle) -> bool:
	if style == null:
		return false
	if not style.has_any_part():
		return false
	if style.rail_profile.size() < 2:
		return false
	if style.ballast_enabled and style.ballast_profile.size() < 2:
		return false
	return true


## Список {level: Level, text: String}. Порядок: ошибки, предупреждения, справка
static func validate(style: TrackStyle) -> Array[Dictionary]:
	var r: Array[Dictionary] = []
	if style == null:
		_add(r, Level.ERROR, "Стиль не загружен")
		return r

	# --- части трака ---
	if not style.has_any_part():
		_add(r, Level.ERROR, "Не включена ни одна часть трака: нужен хотя бы балласт, шпалы или рельсы")
	if not style.rail_enabled:
		_add(r, Level.INFO, "Рельс выключен: только визуал. Профиль рельса, колея и коллизия головки работают как раньше, высота трака не меняется")
	if not style.sleeper_enabled:
		_add(r, Level.INFO, "Шпала выключена: только визуал. Размер шпалы по-прежнему задаёт высоту постели рельса и высоту трака")

	# --- профили ---
	_check_profile(r, "Профиль рельса", style.rail_profile, 3)
	if style.ballast_enabled:
		_check_profile(r, "Профиль балласта", style.ballast_profile, 3)

	# --- рельсы ---
	var rail_hi := 0.0
	if style.rail_profile.size() >= 2:
		var rx := _x_range(style.rail_profile)
		rail_hi = rx.y
		if style.rail_x <= 0.0:
			_add(r, Level.ERROR, "rail_x должен быть больше 0 (сейчас %s)" % _f(style.rail_x))
		elif style.rail_x + rx.x < TOL:
			_add(r, Level.ERROR, "Рельсы сходятся: внутренний край левого и правого рельса на расстоянии %s от оси" % _f(style.rail_x + rx.x))
		if style.rail_height() <= 0.0:
			_add(r, Level.ERROR, "Высота рельса 0: все точки профиля на y = 0")

	# --- шпала ---
	var dims := style.sleeper_dims()
	if dims.x <= 0.0 or dims.y <= 0.0 or dims.z <= 0.0:
		_add(r, Level.ERROR, "Размер шпалы нулевой: %s" % _v3(dims))
	if style.sleeper_enabled and style.sleeper_gap < 0.0:
		_add(r, Level.ERROR, "sleeper_gap меньше 0: шпалы наезжают друг на друга")
	if style.ballast_enabled and (style.sleeper_embed < 0.0 or style.sleeper_embed > dims.y):
		_add(r, Level.WARN, "sleeper_embed %s вне диапазона 0..%s (высота шпалы)" % [_f(style.sleeper_embed), _f(dims.y)])
	if style.sleeper_enabled and dims.x * 0.5 < style.rail_x + rail_hi:
		_add(r, Level.ERROR, "Шпала уже колеи: полуширина шпалы %s, внешний край рельса %s" % [_f(dims.x * 0.5), _f(style.rail_x + rail_hi)])
	if style.sleeper_enabled and style.sleeper_mesh:
		_check_sleeper_mesh(r, style)

	# --- балласт и коллизия ---
	var need := dims.x
	if style.ballast_enabled and style.ballast_profile.size() >= 2:
		var bx := _x_range(style.ballast_profile)
		var half := maxf(absf(bx.x), absf(bx.y))
		need = half * 2.0
		if half < style.rail_x + rail_hi:
			_add(r, Level.WARN, "Балласт уже колеи: полуширина %s, внешний край рельса %s" % [_f(half), _f(style.rail_x + rail_hi)])
	if absf(style.collision_width - need) > COLLISION_TOL:
		_add(r, Level.WARN, "collision_width %s не совпадает с шириной основания %s: коллизия не по видимой форме" % [_f(style.collision_width), _f(need)])

	# --- UV ---
	if style.rail_enabled and (style.rail_uv_tile.x < 0.0 or style.rail_uv_tile.y < 0.0):
		_add(r, Level.ERROR, "rail_uv_tile не может быть отрицательным")
	if style.ballast_uv_tile.x < 0.0 or style.ballast_uv_tile.y < 0.0:
		_add(r, Level.ERROR, "ballast_uv_tile не может быть отрицательным")

	# --- материалы ---
	if style.rail_enabled and style.rail_material == null:
		_add(r, Level.INFO, "rail_material пуст: общий серый материал рельсов")
	if style.ballast_enabled and style.ballast_material == null:
		_add(r, Level.INFO, "ballast_material пуст: общий серый материал балласта")
	if style.sleeper_enabled and style.sleeper_material == null and style.sleeper_mesh == null:
		_add(r, Level.INFO, "sleeper_material пуст: общий коричневый материал шпал")
	if style.sleeper_enabled and style.sleeper_mesh and style.sleeper_material and style.sleeper_mesh.get_surface_count() > 1:
		_add(r, Level.WARN, "sleeper_material перекрывает материалы всех %d поверхностей меша шпалы; чтобы сохранить их, оставьте sleeper_material пустым" % style.sleeper_mesh.get_surface_count())

	# --- высота ---
	var head := style.head_height()
	var head_ref := DEFAULT_HEAD_BALLAST if style.ballast_enabled else DEFAULT_HEAD_PLAIN
	if absf(head - head_ref) > 0.001:
		_add(r, Level.INFO, "Поверхность катания %s, у встроенных стилей %s. Электрическая связь со стыкуемым траком другой высоты не создаётся (допуск 0.05, ATTN_15 §2.10)" % [_f(head), _f(head_ref)])

	# Сначала ошибки, потом предупреждения, потом справка (порядок внутри уровня сохраняется)
	var sorted: Array[Dictionary] = []
	for lv in [Level.ERROR, Level.WARN, Level.INFO]:
		for e in r:
			if e.level == lv:
				sorted.append(e)
	return sorted


## Производные числа для паспорта: [[название, значение], ...]
static func numbers(style: TrackStyle) -> Array:
	var out: Array = []
	if style == null:
		return out
	var dims := style.sleeper_dims()
	var step := style.sleeper_step()
	var parts: PackedStringArray = []
	if style.ballast_enabled:
		parts.append("балласт")
	if style.sleeper_enabled:
		parts.append("шпалы")
	if style.rail_enabled:
		parts.append("рельсы")
	out.append(["Части трака", ", ".join(parts) if not parts.is_empty() else "нет"])
	out.append(["Поверхность катания (head_height)", _f(style.head_height())])
	out.append(["Низ рельса (base_height)", _f(style.base_height())])
	out.append(["Низ шпалы над origin", _f(style.sleeper_bottom())])
	out.append(["Высота балласта", _f(style.ballast_height())])
	out.append(["Высота рельса", _f(style.rail_height())])
	out.append(["Ширина подошвы рельса (rail_width)", _f(style.rail_width())])
	out.append(["Колея (между осями рельсов)", _f(style.rail_x * 2.0)])
	out.append(["Шпала, размер", _v3(dims)])
	out.append(["Шаг шпал", _f(step)])
	out.append(["Шпал на 10 ю", "0 (выключены)" if not style.sleeper_enabled else ("%.1f" % (10.0 / step) if step > 0.0 else "-")])
	if style.sleeper_mesh:
		out.append(["Треугольников на шпалу", str(_tris(style.sleeper_mesh))])
	else:
		out.append(["Треугольников на шпалу", "12 (BoxMesh)"])
	var b := budget(style)
	if not b.is_empty():
		out.append(["Треугольников на 10 ю: меш / шпалы / всего", "%d / %d (≈%d шп.) / %d" % [b["mesh"], b["sleepers"], b["sleeper_count"], b["total"]]])
	out.append(["Точек профиля: рельс / балласт", "%d / %d" % [style.rail_profile.size(), style.ballast_profile.size() if style.ballast_enabled else 0]])
	return out


## Бюджет геометрии на 10 ю прямого трака: {mesh, sleepers, sleeper_count, per_sleeper, total}.
## Меш строится тем же TrackMeshBuilder, что в игре; число шпал приблизительное (10 / шаг)
@warning_ignore("integer_division")
static func budget(style: TrackStyle) -> Dictionary:
	if not can_build(style):
		return {}
	var curve := Curve3D.new()
	curve.add_point(Vector3.ZERO)
	curve.add_point(Vector3(0.0, 0.0, -10.0))
	var am := TrackMeshBuilder.build_mesh(style, curve, 10.0, false)
	var mesh_tris := 0
	for i in am.get_surface_count():
		var arrays := am.surface_get_arrays(i)
		var idx = arrays[Mesh.ARRAY_INDEX]
		mesh_tris += (idx.size() if idx != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	var step := style.sleeper_step()
	var count := int(ceil(10.0 / step)) if step > 0.0 and style.sleeper_enabled else 0
	var per := _tris(style.sleeper_mesh) if style.sleeper_mesh else 12
	return {"mesh": mesh_tris, "sleepers": count * per, "sleeper_count": count, "per_sleeper": per, "total": mesh_tris + count * per}


## Пояснение для вкладок студии, когда часть трака выключена в стиле. part: "rail", "sleeper", "ballast".
## Пустая строка = часть включена
static func part_note(style: TrackStyle, part: String) -> String:
	if style == null:
		return ""
	match part:
		"rail":
			if not style.rail_enabled:
				return "Рельс выключен в стиле: на экране его нет. Профиль и колея по-прежнему задают коллизию и высоту трака, поэтому правятся как обычно."
		"sleeper":
			if not style.sleeper_enabled:
				return "Шпалы выключены в стиле: на экране их нет. Размер шпалы по-прежнему задаёт высоту постели рельса и высоту трака."
		"ballast":
			if not style.ballast_enabled:
				return "Балласт выключен в стиле: профиль и материал балласта не используются."
	return ""


# ==========================================
# Внутреннее
# ==========================================

static func _check_profile(r: Array[Dictionary], title: String, p: PackedVector2Array, min_points: int) -> void:
	if p.size() < 2:
		_add(r, Level.ERROR, "%s: нужно минимум 2 точки (сейчас %d)" % [title, p.size()])
		return
	if p.size() < min_points:
		_add(r, Level.WARN, "%s: всего %d точки, форма будет очень простой" % [title, p.size()])
	var miny := INF
	for v in p:
		miny = minf(miny, v.y)
	if miny < -0.001:
		_add(r, Level.ERROR, "%s: есть точки ниже y = 0 (минимум %s)" % [title, _f(miny)])
	elif miny > 0.001:
		_add(r, Level.WARN, "%s: самая нижняя точка на y = %s, а низ профиля должен быть на 0" % [title, _f(miny)])
	if p[0].x >= p[p.size() - 1].x:
		_add(r, Level.ERROR, "%s: обход должен идти слева направо (первая точка левее последней), иначе нормали вывернуты" % title)
	var zero := 0
	for i in p.size() - 1:
		if p[i].distance_squared_to(p[i + 1]) < 1e-8:
			zero += 1
	if zero > 0:
		_add(r, Level.WARN, "%s: %d повторяющихся подряд точек (нулевые сегменты пропускаются)" % [title, zero])
	var cross := _first_self_intersection(p)
	if cross.x >= 0:
		_add(r, Level.ERROR, "%s: ломаная пересекает сама себя (сегменты %d и %d)" % [title, cross.x + 1, cross.y + 1])


static func _check_sleeper_mesh(r: Array[Dictionary], style: TrackStyle) -> void:
	var a := style.sleeper_mesh.get_aabb()
	var c := a.get_center()
	if absf(c.x) > TOL or absf(c.z) > TOL:
		_add(r, Level.WARN, "Меш шпалы: центр площади опоры смещён на (%s; %s), origin должен быть в центре" % [_f(c.x), _f(c.z)])
	if absf(a.position.y) > TOL:
		_add(r, Level.WARN, "Меш шпалы: низ на y = %s, должен быть на 0" % _f(a.position.y))
	if a.size.x < a.size.z:
		_add(r, Level.WARN, "Меш шпалы: длинная сторона вдоль пути (X %s, Z %s). Шпала лежит поперёк пути: длинная сторона должна быть по X" % [_f(a.size.x), _f(a.size.z)])
	var seat := float(style.sleeper_mesh.get_meta("seat_height", 0.0))
	if seat > 0.0:
		if seat >= a.size.y:
			_add(r, Level.WARN, "Меш шпалы: seat_height %s не ниже высоты меша %s, смысла в метаданных нет" % [_f(seat), _f(a.size.y)])
		else:
			_add(r, Level.INFO, "Меш шпалы: рельс стоит на высоте %s (seat_height), детали выше (подкладки) не поднимают его" % _f(seat))
	var t := _tris(style.sleeper_mesh)
	if t > SLEEPER_TRIS_WARN:
		_add(r, Level.WARN, "Меш шпалы: %d треугольников, шпал на трак сотни (ориентир до %d)" % [t, SLEEPER_TRIS_WARN])


@warning_ignore("integer_division")
static func _tris(m: Mesh) -> int:
	@warning_ignore("integer_division")
	return m.get_faces().size() / 3


## Диапазон x ломаной: Vector2(min, max)
static func _x_range(p: PackedVector2Array) -> Vector2:
	var lo := INF
	var hi := -INF
	for v in p:
		lo = minf(lo, v.x)
		hi = maxf(hi, v.x)
	return Vector2(lo, hi)


## Первая пара несоседних сегментов, которые пересекаются. (-1, -1) = нет
static func _first_self_intersection(p: PackedVector2Array) -> Vector2i:
	var n := p.size() - 1   # сегментов
	for i in n:
		for j in range(i + 2, n):
			if Geometry2D.segment_intersects_segment(p[i], p[i + 1], p[j], p[j + 1]) != null:
				return Vector2i(i, j)
	return Vector2i(-1, -1)


static func _add(r: Array[Dictionary], level: int, text: String) -> void:
	r.append({"level": level, "text": text})


static func _f(v: float) -> String:
	return ("%.3f" % v).rstrip("0").rstrip(".")


static func _v3(v: Vector3) -> String:
	return "%s × %s × %s" % [_f(v.x), _f(v.y), _f(v.z)]
