extends Node3D

# XX claude-terra 13.14 H0 (новый файл)
########################
## H0. Спайк поля высот (ATTN_13 §13.14). Не часть игры: замер и проверка рисков до основной работы
########################
## Запуск: открыть tests/field_spike/field_spike.tscn и нажать F6.
## Что внутри: поле высот 400 x 200 ячеек (стол 200 x 100 ю, ячейка 0,5 ю) в чанках, живой меш, кисть, коллизия по отпусканию.
## Поле здесь плотное (один массив), в H1 оно станет разреженным по чанкам; для замера меша и коллизии это не важно.
## Что печатает в Output (строки «H0»): автопроверки «H0: проверок n/m», время сборки мира, итоги замера по клавише B.
## Что смотреть глазами: рельеф без швов на границах чанков, кольцо кисти идёт по поверхности, шарик (G) катится по рельефу
## после обновления коллизии (около 0,25 с после последнего штриха), а до этого проваливается или стоит на старом.
##
## Управление:
##   Ctrl+колесо  поднять / опустить рельеф вокруг курсора (вверх холм, вниз яма)
##   Alt+колесо   диаметр мазка
##   ЛКМ          зажать и вести: сглаживание под курсором
##   [ ]          угол сглаживания (круче этого угла склоны под кистью выравниваются)
##   ПКМ вращать, СКМ сдвиг, колесо зум
##   C тип коллизии (нет / HeightMapShape3D / trimesh)   K размер чанка 8 / 16 / 32
##   B замер: 100 штрихов (подъём и сглаживание) с печатью итогов   G шарик под курсор   R сброс поля

const STEP := 0.5                     ## ячейка поля, ю (terrain_grid_step * 0,5)
const W := 400                        ## ячеек по X
const D := 200                        ## ячеек по Z
const LAYER := 1.0                    ## толщина слоя, ю (GlobalSetting.layer_height)
const BASE_H := 1.0 * LAYER           ## базовый слой шпатлёвки (13.14: 1 слой)
const MAX_H := 16.0 * LAYER           ## потолок без листа сверху
const RAISE_PER_NOTCH := 0.25 * LAYER ## высота штриха на один щелчок колеса в центре кисти
const DIAM_MIN := 2.0
const DIAM_MAX := 60.0
const DIAM_STEP := 1.0
const ANGLE_MIN := 5.0
const ANGLE_MAX := 85.0
const ANGLE_STEP := 5.0
const BLUR_K := 0.35                  ## доля смещения к среднему соседей за один проход сглаживания
const SLOPE_ITERS := 3                ## проходов выравнивания крутизны за один проход сглаживания
const COLL_IDLE := 0.25               ## пауза после последнего штриха до обновления коллизии, с
const RING_N := 48
const BALLS_MAX := 20
const CHUNK_SIZES: Array[int] = [8, 16, 32]
const COLL_NAMES: Array[String] = ["нет", "HeightMapShape3D", "trimesh (create_trimesh_shape)"]

var _h := PackedFloat32Array()        ## высоты узлов, индекс iz * _stride + ix
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
var _diam := 10.0
var _angle := 30.0
var _hover := Vector3.ZERO
var _hover_ok := false
var _smoothing := false
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
	rm.albedo_color = Color(1.0, 0.9, 0.2)
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
# ПОЛЕ: ДАННЫЕ И КИСТИ
# ==========================================

func _reset_field() -> void:
	_h.resize((W + 1) * (D + 1))
	_h.fill(BASE_H)


## Высота поверхности в точке мира (билинейно по узлам)
func _sample(x: float, z: float) -> float:
	var gx := clampf(x / STEP, 0.0, float(W) - 0.0001)
	var gz := clampf(z / STEP, 0.0, float(D) - 0.0001)
	var ix := int(gx)
	var iz := int(gz)
	var fx := gx - float(ix)
	var fz := gz - float(iz)
	var i := iz * _stride + ix
	return lerpf(lerpf(_h[i], _h[i + 1], fx), lerpf(_h[i + _stride], _h[i + _stride + 1], fx), fz)


## Узловой прямоугольник под кистью: Rect2i(x0, z0, ширина, высота) в узлах поля
func _brush_rect(c: Vector3, rc: float) -> Rect2i:
	var cx := c.x / STEP
	var cz := c.z / STEP
	var x0 := maxi(0, floori(cx - rc))
	var x1 := mini(W, ceili(cx + rc))
	var z0 := maxi(0, floori(cz - rc))
	var z1 := mini(D, ceili(cz + rc))
	return Rect2i(x0, z0, x1 - x0 + 1, z1 - z0 + 1)


## Подъём или опускание: колоколообразный профиль, пол 0 (стол), потолок MAX_H
func _apply_raise(c: Vector3, amount: float) -> Rect2i:
	var rc := _diam * 0.5 / STEP
	var rect := _brush_rect(c, rc)
	var cx := c.x / STEP
	var cz := c.z / STEP
	for iz in range(rect.position.y, rect.end.y):
		var dz := float(iz) - cz
		for ix in range(rect.position.x, rect.end.x):
			var dx := float(ix) - cx
			var d := sqrt(dx * dx + dz * dz) / rc
			if d >= 1.0:
				continue
			var w := 0.5 + 0.5 * cos(PI * d)
			var k := iz * _stride + ix
			_h[k] = clampf(_h[k] + amount * w, 0.0, MAX_H)
	return rect


## Сглаживание: лёгкое размытие по соседям плюс выравнивание склонов круче угла (перенос высоты с сохранением массы)
func _apply_smooth(c: Vector3) -> Rect2i:
	var rc := _diam * 0.5 / STEP
	var rect := _brush_rect(c, rc)
	var cx := c.x / STEP
	var cz := c.z / STEP
	var x0 := rect.position.x
	var z0 := rect.position.y
	var bw := rect.size.x
	var bh := rect.size.y
	var wts := PackedFloat32Array()
	wts.resize(bw * bh)
	for j in range(bh):
		var dz := float(z0 + j) - cz
		for i in range(bw):
			var dx := float(x0 + i) - cx
			var d := sqrt(dx * dx + dz * dz) / rc
			wts[j * bw + i] = (0.5 + 0.5 * cos(PI * d)) if d < 1.0 else 0.0
	# 1. размытие: читаем снимок, пишем в поле
	var src := _h.duplicate()
	for j in range(bh):
		var gz := z0 + j
		var zu := maxi(gz - 1, 0) * _stride
		var zd := mini(gz + 1, D) * _stride
		for i in range(bw):
			var w := wts[j * bw + i]
			if w <= 0.0:
				continue
			var gx := x0 + i
			var k := gz * _stride + gx
			var avg := (src[gz * _stride + maxi(gx - 1, 0)] + src[gz * _stride + mini(gx + 1, W)] + src[zu + gx] + src[zd + gx]) * 0.25
			_h[k] = lerpf(src[k], avg, BLUR_K * w)
	# 2. выравнивание крутизны: пары соседних узлов, где перепад выше tan(угол) * шаг
	var lim := tan(deg_to_rad(_angle)) * STEP
	for _it in range(SLOPE_ITERS):
		var snap := _h.duplicate()
		for j in range(bh):
			for i in range(bw):
				var w0 := wts[j * bw + i]
				if w0 <= 0.0:
					continue
				var k := (z0 + j) * _stride + x0 + i
				if i + 1 < bw:
					var w1 := wts[j * bw + i + 1]
					if w1 > 0.0:
						_relax(snap, k, k + 1, lim, minf(w0, w1))
				if j + 1 < bh:
					var w2 := wts[(j + 1) * bw + i]
					if w2 > 0.0:
						_relax(snap, k, k + _stride, lim, minf(w0, w2))
	for j in range(bh):
		for i in range(bw):
			var k := (z0 + j) * _stride + x0 + i
			_h[k] = clampf(_h[k], 0.0, MAX_H)
	return rect


## Перенос высоты с более высокого узла на более низкий, если перепад больше lim
func _relax(snap: PackedFloat32Array, a: int, b: int, lim: float, w: float) -> void:
	var diff := snap[a] - snap[b]
	var ad := absf(diff)
	if ad <= lim:
		return
	var t := (ad - lim) * 0.25 * w
	if diff > 0.0:
		_h[a] -= t
		_h[b] += t
	else:
		_h[a] += t
		_h[b] -= t


## Наибольший перепад между соседними узлами в прямоугольнике (для проверки сглаживания)
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


func _color_for(h: float) -> Color:
	if h < 0.02:
		return Color(0.42, 0.33, 0.24)
	var t := clampf(h / (MAX_H * 0.6), 0.0, 1.0)
	return Color(0.33, 0.58, 0.22).lerp(Color(0.62, 0.61, 0.58), t)


## Меш одного чанка. Нормали считаются по общему полю, поэтому на границах чанков швов нет
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
			var h := _h[gz * _stride + gx]
			var dhx := (_h[gz * _stride + xr] - _h[gz * _stride + xl]) / sx
			var dhz := (_h[zd * _stride + gx] - _h[zu * _stride + gx]) / sz
			verts[k] = Vector3(float(ix) * STEP, h, float(iz) * STEP)
			norms[k] = Vector3(-dhx, 1.0, -dhz).normalized()
			cols[k] = _color_for(h)
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


func _update_ring() -> void:
	_ring_mesh.clear_surfaces()
	if not _hover_ok:
		return
	var r := _diam * 0.5
	_ring_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(RING_N + 1):
		var a := TAU * float(i) / float(RING_N)
		var x := clampf(_hover.x + cos(a) * r, 0.0, W * STEP)
		var z := clampf(_hover.z + sin(a) * r, 0.0, D * STEP)
		_ring_mesh.surface_add_vertex(Vector3(x, _sample(x, z) + 0.15, z))
	_ring_mesh.surface_end()


# ==========================================
# ШТРИХИ И ЗАМЕР
# ==========================================

func _reset_stats() -> void:
	_stat_n = 0
	_stat_sum = 0.0
	_stat_max = 0.0
	_last = {}


func _record(kind: String, t_data: int, t_mesh: int, chunks: int) -> void:
	var total := float(t_data + t_mesh) / 1000.0
	_last = {"kind": kind, "data": float(t_data) / 1000.0, "mesh": float(t_mesh) / 1000.0, "chunks": chunks}
	_stat_n += 1
	_stat_sum += total
	_stat_max = maxf(_stat_max, total)
	_idle = 0.0


func _raise_at_cursor(dir_: float) -> void:
	if not _hover_ok:
		return
	var t0 := Time.get_ticks_usec()
	var rect := _apply_raise(_hover, RAISE_PER_NOTCH * dir_)
	var t1 := Time.get_ticks_usec()
	var n := _rebuild_region(rect)
	var t2 := Time.get_ticks_usec()
	_record("подъём" if dir_ > 0.0 else "опускание", t1 - t0, t2 - t1, n)


func _smooth_at_cursor() -> void:
	var t0 := Time.get_ticks_usec()
	var rect := _apply_smooth(_hover)
	var t1 := Time.get_ticks_usec()
	var n := _rebuild_region(rect)
	var t2 := Time.get_ticks_usec()
	_record("сглаживание", t1 - t0, t2 - t1, n)


## 100 штрихов в случайных местах (50 подъём, 50 сглаживание) с текущими диаметром, углом, размером чанка и типом коллизии
func _benchmark() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var names := ["подъём", "сглаживание"]
	var sum_d := [0.0, 0.0]
	var sum_m := [0.0, 0.0]
	var max_t := [0.0, 0.0]
	var sum_c := [0, 0]
	var cnt := [0, 0]
	var r := _diam * 0.5
	_coll_dirty.clear()
	for s in range(100):
		var kind := s % 2
		var c := Vector3(rng.randf_range(r, W * STEP - r), 0.0, rng.randf_range(r, D * STEP - r))
		var t0 := Time.get_ticks_usec()
		var rect := _apply_raise(c, RAISE_PER_NOTCH) if kind == 0 else _apply_smooth(c)
		var t1 := Time.get_ticks_usec()
		var n := _rebuild_region(rect)
		var t2 := Time.get_ticks_usec()
		var td := float(t1 - t0) / 1000.0
		var tm := float(t2 - t1) / 1000.0
		sum_d[kind] += td
		sum_m[kind] += tm
		max_t[kind] = maxf(max_t[kind], td + tm)
		sum_c[kind] += n
		cnt[kind] += 1
	print("H0: замер: чанк %d, диаметр %.0f ю, угол %.0f°, 100 штрихов" % [_chunk, _diam, _angle])
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
	var saved_diam := _diam
	var saved_angle := _angle
	_diam = 6.0
	var c := Vector3(50.0, 0.0, 25.0)               # узел (100, 50)
	var ck := 50 * _stride + 100
	# подъём: центр поднялся на шаг, за радиусом без изменений
	_apply_raise(c, 0.25)
	_check("подъём: центр", is_equal_approx(_h[ck], BASE_H + 0.25))
	_check("подъём: вне кисти без изменений", is_equal_approx(_h[50 * _stride + 110], BASE_H))
	# пол: яма не глубже стола
	_reset_field()
	var low_ok := true
	for _i in range(20):
		_apply_raise(c, -0.25)
	for iz in range(40, 61):
		for ix in range(90, 111):
			if _h[iz * _stride + ix] < 0.0:
				low_ok = false
	_check("пол: не ниже стола", low_ok and is_equal_approx(_h[ck], 0.0))
	# потолок
	_reset_field()
	for _i in range(100):
		_apply_raise(c, 0.25)
	_check("потолок: не выше MAX_H", is_equal_approx(_h[ck], MAX_H))
	# сглаживание: пик и крутизна снижаются
	_reset_field()
	_diam = 12.0
	for _i in range(30):
		_apply_raise(c, 0.25)
	var peak0 := _h[ck]
	var rect := _brush_rect(c, _diam * 0.5 / STEP)
	var slope0 := _max_edge_diff(rect)
	_angle = 30.0
	for _i in range(30):
		_apply_smooth(c)
	var peak1 := _h[ck]
	var slope1 := _max_edge_diff(rect)
	_check("сглаживание: пик ниже", peak1 < peak0 - 0.01 and not is_nan(peak1))
	_check("сглаживание: перепад между соседями меньше", slope1 < slope0 - 0.01)
	# чанки: штрих у границы затрагивает 2 чанка и меши сходятся по шву, штрих в середине чанка один
	_reset_field()
	_rebuild_all()
	_diam = 2.0
	var half := _chunk >> 1
	var border := Vector3(float(_chunk) * STEP, 0.0, float(3 * _chunk + half) * STEP)
	var nb := _rebuild_region(_apply_raise(border, 0.5))
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
	_check("чанки: штрих в середине чанка пересобирает один", _rebuild_region(_apply_raise(inner, 0.5)) == 1)
	# выбор точки: луч сверху на ровном поле попадает в базовый слой, луч вверх мимо
	_reset_field()
	var hit: Variant = _pick_ray(Vector3(25.0, 40.0, 12.5), Vector3.DOWN)
	_check("выбор: луч вниз попадает в базовый слой", hit != null and absf((hit as Vector3).y - BASE_H) < 0.01 and absf((hit as Vector3).x - 25.0) < 0.01)
	_check("выбор: луч вверх мимо", _pick_ray(Vector3(25.0, 40.0, 12.5), Vector3.UP) == null)
	_diam = saved_diam
	_angle = saved_angle
	print("H0: проверок %d/%d" % [_ck_ok, _ck_n])


# ==========================================
# ВВОД И ИНТЕРФЕЙС
# ==========================================

func _process(delta: float) -> void:
	_update_hover()
	if _smoothing and _hover_ok:
		_smooth_at_cursor()
	if not _coll_dirty.is_empty():
		if _smoothing:
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
				_smoothing = mb.pressed
			MOUSE_BUTTON_RIGHT:
				_orbiting = mb.pressed
			MOUSE_BUTTON_MIDDLE:
				_panning = mb.pressed
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_on_wheel(mb.button_index == MOUSE_BUTTON_WHEEL_UP, mb.ctrl_pressed, mb.alt_pressed)
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


func _on_wheel(up: bool, ctrl: bool, alt: bool) -> void:
	if ctrl:
		_raise_at_cursor(1.0 if up else -1.0)
	elif alt:
		_diam = clampf(_diam + (DIAM_STEP if up else -DIAM_STEP), DIAM_MIN, DIAM_MAX)
	else:
		_dist = clampf(_dist * (0.9 if up else 1.1), 5.0, 800.0)
		_update_camera()


func _on_key(key: Key) -> void:
	match key:
		KEY_BRACKETLEFT:
			_angle = clampf(_angle - ANGLE_STEP, ANGLE_MIN, ANGLE_MAX)
		KEY_BRACKETRIGHT:
			_angle = clampf(_angle + ANGLE_STEP, ANGLE_MIN, ANGLE_MAX)
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


func _update_hud() -> void:
	var lines := PackedStringArray()
	lines.append("H0 спайк поля высот  |  %dx%d ячеек по %.1f ю, стол %.0fx%.0f ю  |  чанк %d (%d шт.), сборка мира %.0f мс  |  коллизия: %s" % [
		W, D, STEP, W * STEP, D * STEP, _chunk, _chunks.size(), _build_ms, COLL_NAMES[_coll_mode]])
	lines.append("Ctrl+колесо подъём/яма, Alt+колесо диаметр, ЛКМ-драг сглаживание, [ ] угол сглаживания, ПКМ вращать, СКМ сдвиг, колесо зум")
	lines.append("C коллизия | K размер чанка | B замер 100 штрихов | G шарик | R сброс")
	var under := "вне поля"
	if _hover_ok:
		under = "%.2f ю (%.2f слоя)" % [_hover.y, _hover.y / LAYER]
	lines.append("диаметр %.0f ю | угол сглаживания %.0f° | высота под курсором: %s | fps %d" % [_diam, _angle, under, Engine.get_frames_per_second()])
	if _last.is_empty():
		lines.append("штрих: пока не было")
	else:
		var avg := _stat_sum / maxf(float(_stat_n), 1.0)
		lines.append("штрих «%s»: данные %.2f мс + меш %.2f мс (%d чанков) | среднее %.2f, макс %.2f мс, штрихов %d" % [
			_last["kind"], _last["data"], _last["mesh"], _last["chunks"], avg, _stat_max, _stat_n])
	lines.append("коллизия: обновлено %d чанков за %.1f мс | ждёт обновления: %d чанков" % [_coll_n, _coll_ms, _coll_dirty.size()])
	_hud.text = "\n".join(lines)
