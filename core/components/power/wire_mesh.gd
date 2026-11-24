class_name WireMesh extends RefCounted

# XX claude-wire W1 (новый файл)
#####################
## Вид провода (ATTN_23 §23.9.5, W1)
#####################
## Двужильный кабель одним ArrayMesh по ломаной: две жилы (красная и чёрная) рядом. «Скрутка» провода это перекрест:
## на середине трассы жилы поворачиваются вокруг оси на пол-оборота и меняются местами.
## Поверхность 0 красная жила, поверхность 1 чёрная. Материалы задаёт владелец меша (C_Wire).

## Радиус жилы, u (1 u = 1 см; кабель 0.14 u на жилу)
const CORE_RADIUS := 0.07
## Граней в сечении жилы
const RADIAL := 6
## Длина перекреста вдоль трассы, u
const TWIST_LEN := 6.0
## Шаг точек при перекресте: на длинном отрезке нужны промежуточные кольца, иначе поворот жил не виден
const TWIST_STEP := 1.0


## line: ломаная в мировых координатах (лучше уже сглаженная). Меньше двух разных точек: пустой меш
static func build(line: PackedVector3Array, twist: bool) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var pts := WireRoute.dedupe(line)
	if pts.size() < 2:
		return mesh
	if twist:
		pts = _densify(pts, TWIST_STEP)
	var n := pts.size()
	# длина от начала до каждой точки
	var along := PackedFloat32Array()
	along.resize(n)
	var acc := 0.0
	for i in n:
		if i > 0:
			acc += pts[i].distance_to(pts[i - 1])
		along[i] = acc
	var total := acc
	# касательные
	var tang := PackedVector3Array()
	tang.resize(n)
	for i in n:
		var d := Vector3.ZERO
		if i == 0:
			d = pts[1] - pts[0]
		elif i == n - 1:
			d = pts[n - 1] - pts[n - 2]
		else:
			d = (pts[i] - pts[i - 1]).normalized() + (pts[i + 1] - pts[i]).normalized()
			if d.length() < 0.0001:   # разворот на 180 градусов
				d = pts[i + 1] - pts[i]
		tang[i] = d.normalized()
	# кадр вдоль трассы: нормаль переносится параллельно, без скрутки на изгибах
	var nrm := PackedVector3Array()
	nrm.resize(n)
	var bin := PackedVector3Array()
	bin.resize(n)
	var prev := Vector3.ZERO
	for i in n:
		var nv := Vector3.ZERO
		if i == 0:
			var ref := Vector3.UP if absf(tang[0].y) < 0.95 else Vector3.RIGHT
			nv = ref - tang[0] * tang[0].dot(ref)
		else:
			nv = prev - tang[i] * tang[i].dot(prev)
		if nv.length() < 0.0001:
			nv = tang[i].cross(Vector3.UP)
			if nv.length() < 0.0001:
				nv = tang[i].cross(Vector3.RIGHT)
		nv = nv.normalized()
		nrm[i] = nv
		bin[i] = tang[i].cross(nv).normalized()
		prev = nv
	# две жилы
	for k in 2:
		var verts := PackedVector3Array()
		var norms := PackedVector3Array()
		var idx := PackedInt32Array()
		for i in n:
			var phi := (_twist_angle(along[i], total) if twist else 0.0) + float(k) * PI
			var lateral := nrm[i] * cos(phi) + bin[i] * sin(phi)
			var center := pts[i] + lateral * CORE_RADIUS
			for j in RADIAL:
				var a := TAU * float(j) / float(RADIAL)
				var dir := nrm[i] * cos(a) + bin[i] * sin(a)
				verts.append(center + dir * CORE_RADIUS)
				norms.append(dir)
		for i in n - 1:
			for j in RADIAL:
				var j2 := (j + 1) % RADIAL
				var ia := i * RADIAL + j
				var ib := i * RADIAL + j2
				var ic := (i + 1) * RADIAL + j
				var id := (i + 1) * RADIAL + j2
				idx.append_array(PackedInt32Array([ia, ic, ib, ib, ic, id]))
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		arrays[Mesh.ARRAY_INDEX] = idx
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Угол поворота жил вокруг оси на расстоянии s от начала: 0 до перекреста, PI после, плавный переход на середине трассы
static func _twist_angle(s: float, total: float) -> float:
	var half := minf(TWIST_LEN, total) * 0.5
	if half < 0.0001:
		return 0.0
	var t := clampf((s - (total * 0.5 - half)) / (2.0 * half), 0.0, 1.0)
	return PI * t * t * (3.0 - 2.0 * t)


## Добавляет точки на длинных отрезках, чтобы шаг не превышал max_len
static func _densify(pts: PackedVector3Array, max_len: float) -> PackedVector3Array:
	var res := PackedVector3Array()
	res.append(pts[0])
	for i in range(1, pts.size()):
		var seg := pts[i - 1].distance_to(pts[i])
		var parts := maxi(1, ceili(seg / max_len))
		for k in range(1, parts + 1):
			res.append(pts[i - 1].lerp(pts[i], float(k) / float(parts)))
	return res
