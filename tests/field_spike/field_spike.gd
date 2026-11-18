extends Node3D

# XX claude-terra 13.14 H0 (новый файл)
########################
## H0. Спайк поля высот (ATTN_13 §13.14). Не часть игры: замер и проверка рисков до основной работы
########################
## Запуск: открыть tests/field_spike/field_spike.tscn и нажать F6.
## Что внутри: поле высот 400 x 200 ячеек (стол 200 x 100 ю, ячейка 0,5 ю) в чанках, живой меш, кисть «площадка + склон»,
## тип поверхности отдельным каналом, коллизия по отпусканию.
## Поле здесь плотное (один массив), в H1 оно станет разреженным по чанкам; для замера меша и коллизии это не важно.
## Что печатает в Output (строки «H0»): автопроверки «H0: проверок n/m», время сборки мира, итоги замера по клавише B.
## Что смотреть глазами: рельеф без швов на границах чанков, кольца кисти идут по поверхности, шарик (G) катится по рельефу
## после обновления коллизии (около 0,25 с после последнего штриха), а до этого проваливается или стоит на старом.
##
## Кисть (усечённый конус): площадка радиуса p и склон шириной w под углом. Внешний край кисти R, склон может выйти за R
## на допуск. Чем круче склон, тем шире площадка: p = R - w, w = перепад / tg(угол). Если склон не вмещается,
## угол смягчается (HUD пишет фактический). Кольца: жёлтое R, голубое площадка, оранжевое фактический край склона.
##
## Управление:
##   Ctrl+колесо   поднять / опустить площадку вокруг курсора (вверх холм, вниз яма); Shift+Ctrl+колесо: до целого слоя
##   Alt+колесо    радиус кисти (запасные клавиши , и .)
##   ЛКМ           зажать и вести: поле под площадкой подтягивается к высоте в точке нажатия, склон как у подъёма
##   [ ]           угол склона     T тип поверхности (гладкая / каменистая / скалистая), сбрасывает угол типа
##   - =           сила ЛКМ        9 0 минимум площадки      7 8 допуск
##   ПКМ вращать, СКМ сдвиг, колесо зум
##   C тип коллизии (нет / HeightMapShape3D / trimesh)   K размер чанка 8 / 16 / 32
##   B замер: 100 штрихов (подъём и выравнивание ЛКМ) с печатью итогов   G шарик под курсор   R сброс поля

const STEP := 0.5                     ## ячейка поля, ю (terrain_grid_step * 0,5)
const W := 400                        ## ячеек по X
const D := 200                        ## ячеек по Z
const LAYER := 1.0                    ## толщина слоя, ю (GlobalSetting.layer_height)
const BASE_H := 1.0 * LAYER           ## базовый слой шпатлёвки (13.14: 1 слой)
const MAX_H := 16.0 * LAYER           ## потолок без листа сверху
const RADIUS_MIN := 1.5               ## радиус кисти, ю
const RADIUS_MAX := 30.0
const RADIUS_STEP := 0.5
const ANGLE_MIN := 5.0                ## угол склона от горизонтали, градусы
const ANGLE_MAX := 90.0
const ANGLE_STEP := 5.0
const PULL_RATE := 12.0               ## скорость подтягивания ЛКМ при силе 1, 1/с (остаток убывает экспоненциально)
const COLL_IDLE := 0.25               ## пауза после последнего штриха до обновления коллизии, с
const RING_N := 48
const BALLS_MAX := 20
const CHUNK_SIZES: Array[int] = [8, 16, 32]
const COLL_NAMES: Array[String] = ["нет", "HeightMapShape3D", "trimesh (create_trimesh_shape)"]
## Типы поверхности: канал по узлам, отдельно от гладкой высоты. Шум добавляется только в меш (коллизия HeightMap идёт по гладкой высоте)
const TYPE_NAMES: Array[String] = ["гладкая", "каменистая", "скалистая"]
const TYPE_ANGLE: Array[float] = [25.0, 45.0, 75.0]   ## угол склона по умолчанию для типа
const TYPE_NOISE: Array[float] = [0.0, 0.12, 0.35]    ## амплитуда шума в меше, ю
const NOISE_FREQ := 0.45
const SLOPE_ROCK0 := 40.0             ## до этого угла цвет типа, дальше плавно скала
const SLOPE_ROCK1 := 55.0
const COL_BARE := Color(0.42, 0.33, 0.24)
const COL_ROCK := Color(0.46, 0.44, 0.42)
const COL_STONY := Color(0.52, 0.5, 0.34)
const COL_ROCKY := Color(0.58, 0.56, 0.53)

var _h := PackedFloat32Array()        ## гладкие высоты узлов, индекс iz * _stride + ix
var _tp := PackedByteArray()          ## тип поверхности узла (индекс в TYPE_NAMES)
var _nz := PackedFloat32Array()       ## шум узла -1..1, считается один раз
var _ver := 0                         ## счётчик изменений поля (для кэша подсказки)
var _stride := W + 1
var _chunk_i := 1
var _chunk: int = 16
var _ncx := 0
var _ncz := 0
var _idx_full := PackedInt32Array()
var _world: Node3D = null
var _chunks: Array = []               ## MeshInstance3D по индексу cz * _ncx + cx
var _coll_bodies: Array = []          ## StaticBody3D или null, тот же индекс
var _coll_dirty := {}                 ## индекс чанка -> true
var _coll_mode := 1
var _idle := 0.0
# параметры кисти (в игре это карточка кисти)
var _radius := 5.0
var _angle := 25.0
var _type := 0
var _plateau_min := 1.0               ## минимальный радиус площадки, ю
var _tol_frac := 0.25                 ## допуск: доля радиуса, на которую склон может выйти за R
var _tol_max := 3.0                   ## и не больше, ю
var _strength := 0.5                  ## сила ЛКМ 0,1..1
var _notch := 0.25 * LAYER            ## высота площадки на один щелчок колеса, ю
var _hover := Vector3.ZERO
var _hover_ok := false
var _leveling := false
var _anchor := 0.0                    ## высота под курсором в момент нажатия ЛКМ
var _orbiting := false
var _panning := false
var _yaw := 0.5
var _pitch := 0.85
var _dist := 170.0
var _target := Vector3(W * STEP * 0.5, 0.0, D * STEP * 0.5)
var _cam: Camera3D
var _hud: Label
var _ring: MeshInstance3D
var _ring_mesh: ImmediateMesh
var _mat: StandardMaterial3D
var _balls: Array = []
var _last := {}
var _last_plan := {}
var _prev_key: Array = []
var _prev_plan := {}
var _stat_n := 0
var _stat_sum := 0.0
var _stat_max := 0.0
var _build_ms := 0.0
var _coll_ms := 0.0
var _coll_n := 0
var _ck_ok := 0
var _ck_n := 0


func _ready() -> void:
	_build_environment()
	_build_hud()
	_build_table()
	_build_noise()
	_reset_field()
	_build_chunks()
	_self_test()
	_reset_field()
	_rebuild_all()
	_reset_stats()
	_collision_all()
	_update_camera()


# ==========================================
# СЦЕНА
# ==========================================

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.17, 0.2)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.75, 0.8)
	env.ambient_light_energy = 0.45
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 40, 0)
	add_child(sun)
	_cam = Camera3D.new()
	_cam.current = true
	_cam.far = 3000.0
	add_child(_cam)
	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 0.95
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ring_mesh = ImmediateMesh.new()
	_ring = MeshInstance3D.new()
	_ring.mesh = _ring_mesh
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.vertex_color_use_as_albedo = true
	rm.no_depth_test = true
	_ring.material_override = rm
	add_child(_ring)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(10, 8)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hud)


## Плита стола под полем: верх чуть ниже нуля, чтобы дно ямы не мерцало
func _build_table() -> void:
	var box := BoxMesh.new()
	box.size = Vector3(W * STEP + 0.4, 0.4, D * STEP + 0.4)
	var mi := MeshInstance3D.new()
	mi.mesh = box
	mi.position = Vector3(W * STEP * 0.5, -0.21, D * STEP * 0.5)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.3, 0.24, 0.18)
	mi.material_override = m
	add_child(mi)


func _update_camera() -> void:
	var dir := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch))
	_cam.position = _target + dir * _dist
	_cam.look_at(_target, Vector3.UP)


# ==========================================
# ПОЛЕ: ДАННЫЕ
# ==========================================

func _build_noise() -> void:
	var fn := FastNoiseLite.new()
	fn.seed = 7
	fn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fn.frequency = NOISE_FREQ
	fn.fractal_type = FastNoiseLite.FRACTAL_FBM
	fn.fractal_octaves = 3
	_nz.resize(_stride * (D + 1))
	for iz in range(D + 1):
		for ix in range(W + 1):
			_nz[iz * _stride + ix] = fn.get_noise_2d(float(ix) * STEP, float(iz) * STEP)


func _reset_field() -> void:
	_h.resize(_stride * (D + 1))
	_h.fill(BASE_H)
	_tp.resize(_stride * (D + 1))
	_tp.fill(0)
	_ver += 1


## Высота гладкой поверхности в точке мира (билинейно по узлам)
func _sample(x: float, z: float) -> float:
	var gx := clampf(x / STEP, 0.0, float(W) - 0.0001)
	var gz := clampf(z / STEP, 0.0, float(D) - 0.0001)
	var ix := int(gx)
	var iz := int(gz)
	var fx := gx - float(ix)
	var fz := gz - float(iz)
	var i := iz * _stride + ix
	return lerpf(lerpf(_h[i], _h[i + 1], fx), lerpf(_h[i + _stride], _h[i + _stride + 1], fx), fz)


## Узловой прямоугольник под кистью радиуса rc (в ячейках): Rect2i(x0, z0, ширина, высота) в узлах поля
func _brush_rect(c: Vector3, rc: float) -> Rect2i:
	var cx := c.x / STEP
	var cz := c.z / STEP
	var x0 := maxi(0, floori(cx - rc))
	var x1 := mini(W, ceili(cx + rc))
	var z0 := maxi(0, floori(cz - rc))
	var z1 := mini(D, ceili(cz + rc))
	return Rect2i(x0, z0, x1 - x0 + 1, z1 - z0 + 1)


## Высота площадки на следующий щелчок колеса: на четверть слоя от текущей или до ближайшего целого слоя
func _next_height(hc: float, dir_: float, whole: bool) -> float:
	var ht := hc + dir_ * _notch
	if whole:
		if dir_ > 0.0:
			ht = (floorf(hc / LAYER + 0.001) + 1.0) * LAYER
		else:
			ht = (ceilf(hc / LAYER - 0.001) - 1.0) * LAYER
	return clampf(ht, 0.0, MAX_H)


# ==========================================
# КИСТЬ: «ПЛОЩАДКА + СКЛОН»
# ==========================================

## План штриха. c центр кисти, ht высота площадки, mode: 1 подъём (только насыпает), -1 яма (только срезает), 0 выравнивание (оба).
## Перепад dh считается по кольцу от минимальной площадки до края с допуском: склон должен дойти до самой низкой (при подъёме)
## или самой высокой (при яме) точки кольца, поэтому на краю обрыва не бывает. На ровном поле это просто высота подъёма.
## Склон: w = dh / tg(угол), но не уже одной ячейки (угол 90° это склон в ячейку) и не шире, чем помещается (иначе угол смягчается).
## Площадка p = R - w, не меньше минимума: тогда склон выходит за R, но не дальше R + допуск.
func _plan(c: Vector3, ht: float, mode: int) -> Dictionary:
	var tol := minf(_radius * _tol_frac, _tol_max)
	var dmax := _radius + tol
	var pmin := minf(_plateau_min, maxf(_radius - STEP, STEP))
	var rmax := dmax / STEP
	var r0 := pmin / STEP
	var rect := _brush_rect(c, rmax)
	var cx := c.x / STEP
	var cz := c.z / STEP
	var r0sq := r0 * r0
	var rmsq := rmax * rmax
	var up := 0.0
	var down := 0.0
	for iz in range(rect.position.y, rect.end.y):
		var dz := float(iz) - cz
		var row := iz * _stride
		for ix in range(rect.position.x, rect.end.x):
			var dx := float(ix) - cx
			var d2 := dx * dx + dz * dz
			if d2 < r0sq or d2 > rmsq:
				continue
			var df := ht - _h[row + ix]
			if df > up:
				up = df
			elif -df > down:
				down = -df
	var dh := up
	if mode < 0:
		dh = down
	elif mode == 0:
		dh = maxf(up, down)
	var t_set := tan(deg_to_rad(minf(_angle, 89.99)))
	var w_min := STEP
	var w_max := maxf(dmax - pmin, w_min)
	var w_want := dh / t_set
	var w := w_want
	var limit := ""
	if w < w_min:
		w = w_min
		limit = "сетка"
	if w > w_max:
		w = w_max
		limit = "место"
	var t_eff := dh / w
	var ang := rad_to_deg(atan(t_eff))
	if limit == "сетка" and (dh < 0.0001 or _angle - ang < 2.0):
		limit = ""
	var p := maxf(pmin, _radius - w)
	return {"ht": ht, "dh": dh, "w": w, "p": p, "e": p + w, "t": t_eff, "ang": ang, "limit": limit}


## Применить план. kk: доля пути к цели за вызов (1 сразу, меньше подтягивает). Тип поверхности пишется там, где изменилась высота,
## а при выравнивании (mode 0) на всей площадке и склоне. Возвращает узловой прямоугольник изменений (size.x = 0, если ничего не изменилось)
func _apply_plan(c: Vector3, pl: Dictionary, mode: int, kk: float) -> Rect2i:
	var ht: float = pl["ht"]
	var p_cells: float = float(pl["p"]) / STEP
	var e_cells: float = float(pl["e"]) / STEP
	var tstep: float = float(pl["t"]) * STEP        # высота на одну ячейку расстояния
	var rect := _brush_rect(c, e_cells)
	var cx := c.x / STEP
	var cz := c.z / STEP
	var tp := _type
	var minx := W + 1
	var maxx := -1
	var minz := D + 1
	var maxz := -1
	for iz in range(rect.position.y, rect.end.y):
		var dz := float(iz) - cz
		var row := iz * _stride
		for ix in range(rect.position.x, rect.end.x):
			var dx := float(ix) - cx
			var d := sqrt(dx * dx + dz * dz)
			if d > e_cells:
				continue
			var k := row + ix
			var hh := _h[k]
			var tgt := ht
			if d <= p_cells:
				if mode > 0:
					tgt = maxf(hh, ht)
				elif mode < 0:
					tgt = minf(hh, ht)
			else:
				var s := (d - p_cells) * tstep
				if mode > 0:
					tgt = maxf(hh, ht - s)
				elif mode < 0:
					tgt = minf(hh, ht + s)
				elif hh > ht:
					tgt = minf(hh, ht + s)
				else:
					tgt = maxf(hh, ht - s)
			var nh := clampf(lerpf(hh, tgt, kk), 0.0, MAX_H)
			var changed := absf(nh - hh) > 0.00005
			if changed:
				_h[k] = nh
			if (changed or mode == 0) and _tp[k] != tp:
				_tp[k] = tp
				changed = true
			if changed:
				minx = mini(minx, ix)
				maxx = maxi(maxx, ix)
				minz = mini(minz, iz)
				maxz = maxi(maxz, iz)
	if maxx < 0:
		return Rect2i()
	_ver += 1
	return Rect2i(minx, minz, maxx - minx + 1, maxz - minz + 1)


func _stroke(c: Vector3, ht: float, mode: int, kk: float) -> Rect2i:
	var pl := _plan(c, ht, mode)
	_last_plan = pl
	return _apply_plan(c, pl, mode, kk)


## Наибольший перепад между соседними узлами в прямоугольнике (для проверки крутизны)
func _max_edge_diff(rect: Rect2i) -> float:
	var m := 0.0
	for iz in range(rect.position.y, rect.end.y - 1):
		for ix in range(rect.position.x, rect.end.x - 1):
			var k := iz * _stride + ix
			m = maxf(m, absf(_h[k] - _h[k + 1]))
			m = maxf(m, absf(_h[k] - _h[k + _stride]))
	return m


# ==========================================
# ЧАНКИ: МЕШ
# ==========================================

func _build_chunks() -> void:
	var t0 := Time.get_ticks_usec()
	if _world != null:
		remove_child(_world)
		_world.queue_free()
	_world = Node3D.new()
	add_child(_world)
	_ncx = ceili(float(W) / float(_chunk))
	_ncz = ceili(float(D) / float(_chunk))
	_chunks.clear()
	_coll_bodies.clear()
	_coll_dirty.clear()
	_idx_full = _make_indices(_chunk, _chunk)
	for cz in range(_ncz):
		for cx in range(_ncx):
			var mi := MeshInstance3D.new()
			mi.mesh = ArrayMesh.new()
			mi.material_override = _mat
			mi.position = Vector3(float(cx * _chunk) * STEP, 0.0, float(cz * _chunk) * STEP)
			_world.add_child(mi)
			_chunks.append(mi)
			_coll_bodies.append(null)
			_build_chunk(cx, cz)
	_build_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	print("H0: мир собран: чанк %d, чанков %d, %.1f мс" % [_chunk, _chunks.size(), _build_ms])


func _rebuild_all() -> void:
	for cz in range(_ncz):
		for cx in range(_ncx):
			_build_chunk(cx, cz)


## Индексы треугольников сетки cw x cd ячеек (по часовой стрелке при взгляде сверху: лицевая сторона в Godot)
func _make_indices(cw: int, cd: int) -> PackedInt32Array:
	var idx := PackedInt32Array()
	idx.resize(cw * cd * 6)
	var vw := cw + 1
	var k := 0
	for iz in range(cd):
		for ix in range(cw):
			var a := iz * vw + ix
			idx[k] = a
			idx[k + 1] = a + 1
			idx[k + 2] = a + vw
			idx[k + 3] = a + 1
			idx[k + 4] = a + vw + 1
			idx[k + 5] = a + vw
			k += 6
	return idx


## Высота узла в меше: гладкая высота плюс шум по типу поверхности
func _dh(i: int) -> float:
	return _h[i] + TYPE_NOISE[_tp[i]] * _nz[i]


## Цвет вершины: цвет типа, выше SLOPE_ROCK0 градусов плавно переходит в скалу (в игре это будет шейдер по нормали)
func _color_for(h: float, ny: float, tp: int) -> Color:
	if h < 0.02 and tp == 0:
		return COL_BARE
	var base := COL_STONY
	if tp == 0:
		base = Color(0.33, 0.58, 0.22).lerp(Color(0.62, 0.61, 0.58), clampf(h / (MAX_H * 0.6), 0.0, 1.0))
	elif tp == 2:
		base = COL_ROCKY
	var ang := rad_to_deg(acos(clampf(ny, -1.0, 1.0)))
	return base.lerp(COL_ROCK, smoothstep(SLOPE_ROCK0, SLOPE_ROCK1, ang))


## Меш одного чанка. Нормали считаются по общему полю (с шумом), поэтому на границах чанков швов нет
func _build_chunk(cx: int, cz: int) -> void:
	var gx0 := cx * _chunk
	var gz0 := cz * _chunk
	var cw := mini(_chunk, W - gx0)
	var cd := mini(_chunk, D - gz0)
	var vw := cw + 1
	var vd := cd + 1
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	verts.resize(vw * vd)
	norms.resize(vw * vd)
	cols.resize(vw * vd)
	var k := 0
	for iz in range(vd):
		var gz := gz0 + iz
		var zu := maxi(gz - 1, 0)
		var zd := mini(gz + 1, D)
		var sz := float(zd - zu) * STEP
		for ix in range(vw):
			var gx := gx0 + ix
			var xl := maxi(gx - 1, 0)
			var xr := mini(gx + 1, W)
			var sx := float(xr - xl) * STEP
			var i0 := gz * _stride + gx
			var h := _dh(i0)
			var dhx := (_dh(gz * _stride + xr) - _dh(gz * _stride + xl)) / sx
			var dhz := (_dh(zd * _stride + gx) - _dh(zu * _stride + gx)) / sz
			var n := Vector3(-dhx, 1.0, -dhz).normalized()
			verts[k] = Vector3(float(ix) * STEP, h, float(iz) * STEP)
			norms[k] = n
			cols[k] = _color_for(h, n.y, _tp[i0])
			k += 1
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = _idx_full if (cw == _chunk and cd == _chunk) else _make_indices(cw, cd)
	var mi := _chunks[cz * _ncx + cx] as MeshInstance3D
	var m := mi.mesh as ArrayMesh
	m.clear_surfaces()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


## Пересобрать чанки, затронутые изменением узлов в rect (узел и его соседи входят в нормали). Возвращает число чанков
func _rebuild_region(rect: Rect2i) -> int:
	var x0 := rect.position.x
	var z0 := rect.position.y
	var x1 := rect.end.x - 1
	var z1 := rect.end.y - 1
	var cx0 := clampi(floori(float(x0 - 2) / float(_chunk)), 0, _ncx - 1)
	var cx1 := clampi(floori(float(x1 + 1) / float(_chunk)), 0, _ncx - 1)
	var cz0 := clampi(floori(float(z0 - 2) / float(_chunk)), 0, _ncz - 1)
	var cz1 := clampi(floori(float(z1 + 1) / float(_chunk)), 0, _ncz - 1)
	var n := 0
	for cz in range(cz0, cz1 + 1):
		for cx in range(cx0, cx1 + 1):
			_build_chunk(cx, cz)
			_coll_dirty[cz * _ncx + cx] = true
			n += 1
	return n


# ==========================================
# КОЛЛИЗИЯ
# ==========================================

func _update_collision() -> void:
	var t0 := Time.get_ticks_usec()
	var n := 0
	if _coll_mode != 0:
		for key in _coll_dirty.keys():
			var ci: int = key
			_make_collision(ci)
			n += 1
	_coll_dirty.clear()
	_coll_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	_coll_n = n


func _make_collision(ci: int) -> void:
	var cx := ci % _ncx
	var cz := floori(float(ci) / float(_ncx))
	var gx0 := cx * _chunk
	var gz0 := cz * _chunk
	var cw := mini(_chunk, W - gx0)
	var cd := mini(_chunk, D - gz0)
	var mi := _chunks[ci] as MeshInstance3D
	var body := _coll_bodies[ci] as StaticBody3D
	if body == null:
		body = StaticBody3D.new()
		body.add_child(CollisionShape3D.new())
		mi.add_child(body)
		_coll_bodies[ci] = body
	var cs := body.get_child(0) as CollisionShape3D
	if _coll_mode == 1:
		# карта высот квадратная (Jolt другую не принимает): крайний чанк дополняется повтором краевых узлов за столом
		var n := maxi(cw, cd) + 1
		var data := PackedFloat32Array()
		data.resize(n * n)
		for iz in range(n):
			var rz := mini(gz0 + iz, D) * _stride
			for ix in range(n):
				data[iz * n + ix] = _h[rz + mini(gx0 + ix, W)]
		var hs := HeightMapShape3D.new()
		hs.map_width = n
		hs.map_depth = n
		hs.map_data = data
		cs.shape = hs
		cs.scale = Vector3(STEP, 1.0, STEP)
		cs.position = Vector3(float(n - 1) * STEP * 0.5, 0.0, float(n - 1) * STEP * 0.5)
	else:
		cs.shape = (mi.mesh as ArrayMesh).create_trimesh_shape()
		cs.scale = Vector3.ONE
		cs.position = Vector3.ZERO


## Заново собрать коллизию всех чанков (после смены типа)
func _collision_all() -> void:
	for ci in range(_chunks.size()):
		var body := _coll_bodies[ci] as StaticBody3D
		if body != null:
			body.queue_free()
			_coll_bodies[ci] = null
		_coll_dirty[ci] = true
	_update_collision()
	print("H0: коллизия «%s»: %d чанков, %.1f мс" % [COLL_NAMES[_coll_mode], _coll_n, _coll_ms])


# ==========================================
# ВЫБОР ТОЧКИ ПОД КУРСОРОМ (луч по данным поля, а не по физике: физика отстаёт до отпускания)
# ==========================================

func _pick_ray(o: Vector3, d: Vector3) -> Variant:
	var bmin := Vector3.ZERO
	var bmax := Vector3(W * STEP, MAX_H, D * STEP)
	var t0 := 0.0
	var t1 := 4000.0
	for a in range(3):
		var oa: float = o[a]
		var da: float = d[a]
		if absf(da) < 0.000001:
			if oa < bmin[a] or oa > bmax[a]:
				return null
		else:
			var ta: float = (bmin[a] - oa) / da
			var tb: float = (bmax[a] - oa) / da
			if ta > tb:
				var tmp := ta
				ta = tb
				tb = tmp
			t0 = maxf(t0, ta)
			t1 = minf(t1, tb)
	if t0 > t1:
		return null
	var t := t0
	var prev_t := t0
	while true:
		var p := o + d * t
		var h := _sample(p.x, p.z)
		if p.y <= h:
			var lo := prev_t
			var hi := t
			for _i in range(10):
				var mid := (lo + hi) * 0.5
				var pm := o + d * mid
				if pm.y <= _sample(pm.x, pm.z):
					hi = mid
				else:
					lo = mid
			var pf := o + d * hi
			return Vector3(pf.x, _sample(pf.x, pf.z), pf.z)
		if t >= t1:
			break
		prev_t = t
		t = minf(t + clampf((p.y - h) * 0.7, STEP * 0.5, STEP * 4.0), t1)
	return null


func _update_hover() -> void:
	if _orbiting or _panning:
		return
	var mp := get_viewport().get_mouse_position()
	var hit: Variant = _pick_ray(_cam.project_ray_origin(mp), _cam.project_ray_normal(mp))
	_hover_ok = hit != null
	if _hover_ok:
		_hover = hit as Vector3


## План следующего щелчка вверх под курсором (для колец и подсказки); пересчитывается, только если что-то изменилось
func _preview() -> Dictionary:
	var whole := Input.is_key_pressed(KEY_SHIFT)
	var key: Array = [floori(_hover.x / STEP), floori(_hover.z / STEP), _ver, _radius, _angle, _plateau_min, _tol_frac, _tol_max, whole]
	if key != _prev_key:
		_prev_key = key
		_prev_plan = _plan(_hover, _next_height(_hover.y, 1.0, whole), 1)
	return _prev_plan


func _draw_ring(r: float, col: Color) -> void:
	_ring_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(RING_N + 1):
		var a := TAU * float(i) / float(RING_N)
		var x := clampf(_hover.x + cos(a) * r, 0.0, W * STEP)
		var z := clampf(_hover.z + sin(a) * r, 0.0, D * STEP)
		_ring_mesh.surface_set_color(col)
		_ring_mesh.surface_add_vertex(Vector3(x, _sample(x, z) + 0.15, z))
	_ring_mesh.surface_end()


func _update_ring() -> void:
	_ring_mesh.clear_surfaces()
	if not _hover_ok:
		return
	var pl := _last_plan if (_leveling and not _last_plan.is_empty()) else _preview()
	_draw_ring(_radius, Color(1.0, 0.9, 0.2))
	_draw_ring(float(pl["p"]), Color(0.3, 0.9, 1.0))
	if float(pl["e"]) - _radius > 0.05:
		_draw_ring(float(pl["e"]), Color(1.0, 0.5, 0.2))


# ==========================================
# ШТРИХИ И ЗАМЕР
# ==========================================

func _reset_stats() -> void:
	_stat_n = 0
	_stat_sum = 0.0
	_stat_max = 0.0
	_last = {}
	_last_plan = {}
	_prev_key = []


func _record(kind: String, t_data: int, t_mesh: int, chunks: int) -> void:
	var total := float(t_data + t_mesh) / 1000.0
	_last = {"kind": kind, "data": float(t_data) / 1000.0, "mesh": float(t_mesh) / 1000.0, "chunks": chunks}
	_stat_n += 1
	_stat_sum += total
	_stat_max = maxf(_stat_max, total)
	_idle = 0.0


func _raise_at_cursor(dir_: float, whole: bool) -> void:
	if not _hover_ok:
		return
	var hc := _sample(_hover.x, _hover.z)
	var ht := _next_height(hc, dir_, whole)
	if absf(ht - hc) < 0.0001:
		return
	var t0 := Time.get_ticks_usec()
	var rect := _stroke(_hover, ht, int(dir_), 1.0)
	var t1 := Time.get_ticks_usec()
	var n := 0
	if rect.size.x > 0:
		n = _rebuild_region(rect)
	var t2 := Time.get_ticks_usec()
	_record("подъём" if dir_ > 0.0 else "яма", t1 - t0, t2 - t1, n)


## Один кадр ЛКМ: подтянуть поле под площадкой к высоте якоря. Если ничего не изменилось, меш не трогаем
func _level_at_cursor(delta: float) -> void:
	var kk := 1.0 - exp(-PULL_RATE * _strength * delta)
	var t0 := Time.get_ticks_usec()
	var rect := _stroke(_hover, _anchor, 0, kk)
	var t1 := Time.get_ticks_usec()
	if rect.size.x <= 0:
		return
	var n := _rebuild_region(rect)
	var t2 := Time.get_ticks_usec()
	_record("выравнивание", t1 - t0, t2 - t1, n)


## 100 штрихов в случайных местах (50 подъём на щелчок, 50 кадров выравнивания ЛКМ) с текущими радиусом, углом, размером чанка и типом коллизии
func _benchmark() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var names := ["подъём", "выравнивание ЛКМ"]
	var sum_d := [0.0, 0.0]
	var sum_m := [0.0, 0.0]
	var max_t := [0.0, 0.0]
	var sum_c := [0, 0]
	var cnt := [0, 0]
	var r := _radius * 1.3 + 1.0
	var kk := 1.0 - exp(-PULL_RATE * _strength / 60.0)
	_coll_dirty.clear()
	for s in range(100):
		var kind := s % 2
		var c := Vector3(rng.randf_range(r, W * STEP - r), 0.0, rng.randf_range(r, D * STEP - r))
		var t0 := Time.get_ticks_usec()
		var hc := _sample(c.x, c.z)
		var rect := Rect2i()
		if kind == 0:
			rect = _stroke(c, minf(hc + _notch, MAX_H), 1, 1.0)
		else:
			rect = _stroke(c, clampf(hc + rng.randf_range(-1.5, 1.5), 0.0, MAX_H), 0, kk)
		var t1 := Time.get_ticks_usec()
		var n := 0
		if rect.size.x > 0:
			n = _rebuild_region(rect)
		var t2 := Time.get_ticks_usec()
		var td := float(t1 - t0) / 1000.0
		var tm := float(t2 - t1) / 1000.0
		sum_d[kind] += td
		sum_m[kind] += tm
		max_t[kind] = maxf(max_t[kind], td + tm)
		sum_c[kind] += n
		cnt[kind] += 1
	print("H0: замер: чанк %d, радиус %.1f ю, угол %.0f°, тип «%s», 100 штрихов" % [_chunk, _radius, _angle, TYPE_NAMES[_type]])
	for kind in range(2):
		var nn: float = float(cnt[kind])
		print("H0:   %s: данные %.2f мс, меш %.2f мс, всего среднее %.2f мс, макс %.2f мс, чанков за штрих %.1f" % [
			names[kind], float(sum_d[kind]) / nn, float(sum_m[kind]) / nn, (float(sum_d[kind]) + float(sum_m[kind])) / nn,
			float(max_t[kind]), float(sum_c[kind]) / nn])
	var dirty := _coll_dirty.size()
	_update_collision()
	print("H0:   коллизия «%s» по отпусканию: %d из %d чанков, %.1f мс (%.2f мс на чанк)" % [
		COLL_NAMES[_coll_mode], _coll_n, dirty, _coll_ms, _coll_ms / maxf(float(_coll_n), 1.0)])
	print("H0:   цель H0: штрих до 10 мс на кадр (данные плюс меш), решение по чанку и коллизии принимаем по этим цифрам")


# ==========================================
# АВТОПРОВЕРКИ
# ==========================================

func _check(what: String, cond: bool) -> void:
	_ck_n += 1
	if cond:
		_ck_ok += 1
	else:
		print("H0: ПРОВАЛ: ", what)


func _self_test() -> void:
	_ck_ok = 0
	_ck_n = 0
	var s_radius := _radius
	var s_angle := _angle
	var s_pmin := _plateau_min
	var s_tolf := _tol_frac
	var s_tolm := _tol_max
	var s_type := _type
	_radius = 5.0
	_angle = 45.0
	_plateau_min = 1.0
	_tol_frac = 0.25
	_tol_max = 3.0
	_type = 0
	var c := Vector3(50.0, 0.0, 25.0)               # узел (100, 50)
	var ck := 50 * _stride + 100
	# подъём на четверть слоя: площадка радиуса 4,5 ю (9 ячеек), склон 0,5 ю, дальше без изменений
	_reset_field()
	var rect := _stroke(c, BASE_H + 0.25, 1, 1.0)
	_check("подъём: центр на высоте площадки", is_equal_approx(_h[ck], BASE_H + 0.25))
	_check("подъём: площадка ровная", is_equal_approx(_h[ck + 7], BASE_H + 0.25) and is_equal_approx(_h[ck - 7 * _stride], BASE_H + 0.25))
	_check("подъём: за склоном без изменений", is_equal_approx(_h[ck + 11], BASE_H) and is_equal_approx(_h[ck + 13], BASE_H))
	_check("подъём: прямоугольник изменений непустой и в пределах кисти", rect.size.x > 0 and rect.position.x >= 90 and rect.end.x <= 111)
	# площадка и склон: подъём на слой при 45° даёт склон 1 ю и площадку 4 ю
	_reset_field()
	var pl := _plan(c, BASE_H + 1.0, 1)
	_check("план 45°: площадка 4 ю, склон 1 ю", is_equal_approx(float(pl["p"]), 4.0) and is_equal_approx(float(pl["w"]), 1.0) and pl["limit"] == "")
	_angle = 30.0
	pl = _plan(c, BASE_H + 2.0, 1)
	_check("план 30°, подъём на 2: площадка около 1,5 ю", absf(float(pl["p"]) - 1.54) < 0.01)
	_angle = 75.0
	pl = _plan(c, BASE_H + 2.0, 1)
	_check("план 75°, подъём на 2: площадка около 4,46 ю", absf(float(pl["p"]) - 4.46) < 0.01)
	_angle = 90.0
	pl = _plan(c, BASE_H + 1.0, 1)
	_check("план 90°: склон в одну ячейку, площадка R - 0,5", is_equal_approx(float(pl["w"]), STEP) and is_equal_approx(float(pl["p"]), 4.5) and pl["limit"] == "сетка")
	_angle = 30.0
	pl = _plan(c, BASE_H + 4.0, 1)
	_check("план: склон не вмещается, угол смягчён (около 37°), площадка в минимуме", pl["limit"] == "место" and absf(float(pl["ang"]) - 37.3) < 0.5 and is_equal_approx(float(pl["p"]), 1.0))
	_check("план: склон не дальше R + допуск", float(pl["e"]) <= 5.0 + 1.25 + 0.001)
	# яма и пол
	_angle = 45.0
	_reset_field()
	_stroke(c, 0.0, -1, 1.0)
	_check("яма: центр на столе", is_equal_approx(_h[ck], 0.0))
	_stroke(c, -3.0, -1, 1.0)
	var low_ok := true
	for iz in range(40, 61):
		for ix in range(90, 111):
			if _h[iz * _stride + ix] < 0.0:
				low_ok = false
	_check("пол: не ниже стола", low_ok and is_equal_approx(_h[ck], 0.0))
	# потолок
	_reset_field()
	_stroke(c, MAX_H + 5.0, 1, 1.0)
	_check("потолок: не выше MAX_H", is_equal_approx(_h[ck], MAX_H))
	# склон не круче угла
	_reset_field()
	var big := _brush_rect(c, 30.0 / STEP)
	_stroke(c, BASE_H + 1.0, 1, 1.0)
	_check("склон 45°: перепад между соседними узлами не больше tg(угла) * шаг", _max_edge_diff(big) <= tan(deg_to_rad(45.0)) * STEP + 0.002)
	# холм и новый штрих на его склоне: нового обрыва нет
	_reset_field()
	_radius = 8.0
	_stroke(c, BASE_H + 4.0, 1, 1.0)
	var c2 := Vector3(56.0, 0.0, 25.0)              # 6 ю от центра холма, узел (112, 50)
	var pre := _max_edge_diff(big)
	_stroke(c2, _sample(c2.x, c2.z) + 0.25, 1, 1.0)
	var post := _max_edge_diff(big)
	_check("холм: штрих на склоне не создаёт обрыва", post <= maxf(pre, tan(deg_to_rad(45.0)) * STEP) + 0.002)
	# ЛКМ: подтягивание к якорю по шагам, потом точно
	var k2 := 50 * _stride + 112
	var before := _h[k2]
	_stroke(c2, 3.0, 0, 0.5)
	_check("ЛКМ: один шаг подтягивает наполовину", absf(_h[k2] - (before + (3.0 - before) * 0.5)) < 0.0001)
	for _i in range(12):
		_stroke(c2, 3.0, 0, 0.5)
	_check("ЛКМ: после удержания высота равна якорю", absf(_h[k2] - 3.0) < 0.01)
	# тип поверхности: подъём пишет тип там, где изменил высоту, ЛКМ на всей площадке и склоне, ровное поле с тем же типом не меняется
	_reset_field()
	_radius = 5.0
	_type = 2
	_stroke(c, BASE_H + 0.25, 1, 1.0)
	_check("тип: подъём пишет тип в центре, вдали тип прежний", _tp[ck] == 2 and _tp[ck + 11] == 0)
	_reset_field()
	_type = 1
	var r0 := _stroke(c, BASE_H, 0, 1.0)
	_check("тип: ЛКМ пишет тип без изменения высоты", r0.size.x > 0 and _tp[ck] == 1 and _tp[ck + 3] == 1 and _tp[ck + 30] == 0 and is_equal_approx(_h[ck], BASE_H))
	var r1 := _stroke(c, BASE_H, 0, 1.0)
	_check("ЛКМ на ровном поле того же типа ничего не меняет", r1.size.x == 0)
	_type = 0
	# чанки: штрих у границы затрагивает 2 чанка и меши сходятся по шву, штрих в середине чанка один
	_reset_field()
	_rebuild_all()
	_radius = 1.5
	var half := _chunk >> 1
	var border := Vector3(float(_chunk) * STEP, 0.0, float(3 * _chunk + half) * STEP)
	var nb := _rebuild_region(_stroke(border, BASE_H + 0.5, 1, 1.0))
	_check("чанки: штрих на границе пересобирает не меньше 2", nb >= 2)
	var gz := 3 * _chunk + half
	var a0 := (_chunks[3 * _ncx] as MeshInstance3D).mesh as ArrayMesh
	var a1 := (_chunks[3 * _ncx + 1] as MeshInstance3D).mesh as ArrayMesh
	var v0 := a0.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var v1 := a1.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var y0 := v0[half * (_chunk + 1) + _chunk].y
	var y1 := v1[half * (_chunk + 1)].y
	_check("чанки: шов сходится с данными", is_equal_approx(y0, y1) and is_equal_approx(y0, _h[gz * _stride + _chunk]) and y0 > BASE_H + 0.1)
	var inner := Vector3(float(half) * STEP, 0.0, float(3 * _chunk + half) * STEP)
	_check("чанки: штрих в середине чанка пересобирает один", _rebuild_region(_stroke(inner, BASE_H + 0.5, 1, 1.0)) == 1)
	# выбор точки: луч сверху на ровном поле попадает в базовый слой, луч вверх мимо
	_reset_field()
	var hit: Variant = _pick_ray(Vector3(25.0, 40.0, 12.5), Vector3.DOWN)
	_check("выбор: луч вниз попадает в базовый слой", hit != null and absf((hit as Vector3).y - BASE_H) < 0.01 and absf((hit as Vector3).x - 25.0) < 0.01)
	_check("выбор: луч вверх мимо", _pick_ray(Vector3(25.0, 40.0, 12.5), Vector3.UP) == null)
	_radius = s_radius
	_angle = s_angle
	_plateau_min = s_pmin
	_tol_frac = s_tolf
	_tol_max = s_tolm
	_type = s_type
	print("H0: проверок %d/%d" % [_ck_ok, _ck_n])


# ==========================================
# ВВОД И ИНТЕРФЕЙС
# ==========================================

func _process(delta: float) -> void:
	_update_hover()
	if _leveling and _hover_ok:
		_level_at_cursor(delta)
	if not _coll_dirty.is_empty():
		if _leveling:
			_idle = 0.0
		else:
			_idle += delta
			if _idle >= COLL_IDLE:
				_update_collision()
	_update_ring()
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_update_hover()
					_leveling = _hover_ok
					_anchor = _hover.y
				else:
					_leveling = false
			MOUSE_BUTTON_RIGHT:
				_orbiting = mb.pressed
			MOUSE_BUTTON_MIDDLE:
				_panning = mb.pressed
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_on_wheel(mb.button_index == MOUSE_BUTTON_WHEEL_UP, mb.ctrl_pressed, mb.alt_pressed, mb.shift_pressed)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _orbiting:
			_yaw -= mm.relative.x * 0.006
			_pitch = clampf(_pitch + mm.relative.y * 0.006, 0.05, 1.5)
			_update_camera()
		elif _panning:
			var right := _cam.global_transform.basis.x
			var fwd := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
			var k := _dist * 0.0016
			_target -= right * mm.relative.x * k
			_target += fwd * mm.relative.y * k
			_update_camera()
	elif event is InputEventKey:
		var ke := event as InputEventKey
		if ke.pressed and not ke.echo:
			# physical_keycode: клавиши работают на любой раскладке
			_on_key(ke.physical_keycode)


func _on_wheel(up: bool, ctrl: bool, alt: bool, shift: bool) -> void:
	if ctrl:
		_raise_at_cursor(1.0 if up else -1.0, shift)
	elif alt:
		_radius = clampf(_radius + (RADIUS_STEP if up else -RADIUS_STEP), RADIUS_MIN, RADIUS_MAX)
	else:
		_dist = clampf(_dist * (0.9 if up else 1.1), 5.0, 800.0)
		_update_camera()


func _on_key(key: Key) -> void:
	match key:
		KEY_BRACKETLEFT:
			_angle = clampf(_angle - ANGLE_STEP, ANGLE_MIN, ANGLE_MAX)
		KEY_BRACKETRIGHT:
			_angle = clampf(_angle + ANGLE_STEP, ANGLE_MIN, ANGLE_MAX)
		KEY_COMMA:
			_radius = clampf(_radius - RADIUS_STEP, RADIUS_MIN, RADIUS_MAX)
		KEY_PERIOD:
			_radius = clampf(_radius + RADIUS_STEP, RADIUS_MIN, RADIUS_MAX)
		KEY_T:
			_type = (_type + 1) % TYPE_NAMES.size()
			_angle = TYPE_ANGLE[_type]
		KEY_MINUS:
			_strength = clampf(_strength - 0.1, 0.1, 1.0)
		KEY_EQUAL:
			_strength = clampf(_strength + 0.1, 0.1, 1.0)
		KEY_9:
			_plateau_min = clampf(_plateau_min - 0.5, 0.5, 3.0)
		KEY_0:
			_plateau_min = clampf(_plateau_min + 0.5, 0.5, 3.0)
		KEY_7:
			_tol_frac = clampf(_tol_frac - 0.05, 0.0, 0.5)
		KEY_8:
			_tol_frac = clampf(_tol_frac + 0.05, 0.0, 0.5)
		KEY_C:
			_coll_mode = (_coll_mode + 1) % COLL_NAMES.size()
			_collision_all()
		KEY_K:
			_chunk_i = (_chunk_i + 1) % CHUNK_SIZES.size()
			_chunk = CHUNK_SIZES[_chunk_i]
			_build_chunks()
			if _coll_mode != 0:
				_collision_all()
			_reset_stats()
		KEY_B:
			_benchmark()
		KEY_R:
			_reset_field()
			_rebuild_all()
			_coll_dirty.clear()
			for ci in range(_chunks.size()):
				_coll_dirty[ci] = true
			_reset_stats()
		KEY_G:
			_drop_ball()


func _drop_ball() -> void:
	if not _hover_ok:
		return
	var rb := RigidBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.8
	cs.shape = sh
	rb.add_child(cs)
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.8
	sm.height = 1.6
	mi.mesh = sm
	rb.add_child(mi)
	add_child(rb)
	rb.global_position = _hover + Vector3(0.0, 12.0, 0.0)
	_balls.append(rb)
	if _balls.size() > BALLS_MAX:
		(_balls.pop_front() as Node).queue_free()


func _limit_text(pl: Dictionary) -> String:
	var lim: String = pl["limit"]
	if lim == "место":
		return " (ограничен: склон не вмещается в кисть с допуском)"
	if lim == "сетка":
		return " (ограничен: склон не уже одной ячейки %.1f ю)" % STEP
	return ""


func _update_hud() -> void:
	var lines := PackedStringArray()
	lines.append("H0 спайк поля высот  |  %dx%d ячеек по %.1f ю, стол %.0fx%.0f ю  |  чанк %d (%d шт.), сборка мира %.0f мс  |  коллизия: %s" % [
		W, D, STEP, W * STEP, D * STEP, _chunk, _chunks.size(), _build_ms, COLL_NAMES[_coll_mode]])
	lines.append("Ctrl+колесо подъём/яма (с Shift до целого слоя), Alt+колесо радиус, ЛКМ-драг выровнять по высоте в точке нажатия, [ ] угол, T тип, ПКМ вращать, СКМ сдвиг, колесо зум")
	lines.append("C коллизия | K размер чанка | B замер 100 штрихов | G шарик | R сброс | - = сила | 9 0 площадка | 7 8 допуск | , . радиус")
	lines.append("кисть: радиус %.1f ю | угол %.0f° | тип «%s» | сила ЛКМ %.1f | мин. площадка %.1f ю | допуск %.0f%% (не больше %.1f ю)" % [
		_radius, _angle, TYPE_NAMES[_type], _strength, _plateau_min, _tol_frac * 100.0, _tol_max])
	if _hover_ok:
		var pl := _preview()
		lines.append("щелчок вверх: площадка r %.1f ю, склон %.1f ю, фактический угол %.0f°%s, склон до %.1f ю от центра" % [
			float(pl["p"]), float(pl["w"]), float(pl["ang"]), _limit_text(pl), float(pl["e"])])
		lines.append("высота под курсором: %.2f ю (%.2f слоя) | якорь ЛКМ %.2f ю | fps %d" % [_hover.y, _hover.y / LAYER, _anchor, Engine.get_frames_per_second()])
	else:
		lines.append("курсор вне поля | fps %d" % Engine.get_frames_per_second())
	if _last.is_empty():
		lines.append("штрих: пока не было")
	else:
		var avg := _stat_sum / maxf(float(_stat_n), 1.0)
		lines.append("штрих «%s»: данные %.2f мс + меш %.2f мс (%d чанков) | среднее %.2f, макс %.2f мс, штрихов %d" % [
			_last["kind"], _last["data"], _last["mesh"], _last["chunks"], avg, _stat_max, _stat_n])
	lines.append("коллизия: обновлено %d чанков за %.1f мс | ждёт обновления: %d чанков" % [_coll_n, _coll_ms, _coll_dirty.size()])
	_hud.text = "\n".join(lines)
