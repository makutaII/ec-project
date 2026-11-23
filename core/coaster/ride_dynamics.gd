@tool
class_name RideDynamics extends RefCounted

###########################
## Нагрузка на вагон на горках: отрыв и боковая сила (ATTN_27 §27.5)
###########################
## Чистая математика, без нод. Вагон на скорости v по кривой с вектором кривизны κ (в сторону центра, 1/ед.) испытывает
## центростремительное ускорение a = v²·κ. Сила трака на единицу массы F = a − g_vec, где g_vec = (0, −g, 0). Раскладываем F
## по «верху» u и «право» r поверхности трака (с учётом крена):
##   n = F·u / g   — нормальная нагрузка в долях g (1 = просто стоит на горизонтальном лотке, 0 = невесомость, < 0 = трак
##                   должен был бы тянуть вагон вниз: на горбе слишком быстро, вагон отрывается, сход «airtime»);
##   l = F·r / g   — боковая нагрузка в долях g (её держат борта; сверх предела вагон вылетает через борт, сход «side»).
## Крен гасит боковую нагрузку сам: у идеального виража F параллельна «верху», l = 0.
## g здесь эффективная тяжесть вагона G·grade_k: та же, что разгоняет его на спуске (C_Chassis.incline_force).

## Шаг запекания профиля по длине, ю
const STEP := 0.5
## Половина базы для разности касательных (кривизна = (t(s+h) − t(s−h)) / (2h)), ю
const HALF_BASE := 0.5


## Нагрузки (n, l) в долях g. speed: скорость вдоль трака (ю/с, знак не важен), kappa, up, right: мировые векторы в точке,
## g_eff: эффективная тяжесть, ю/с²
static func loads(speed: float, kappa: Vector3, up: Vector3, right: Vector3, g_eff: float) -> Vector2:
	var g := maxf(g_eff, 0.001)
	var f := kappa * speed * speed + Vector3(0.0, g, 0.0)
	return Vector2(f.dot(up) / g, f.dot(right) / g)


## Запекание профиля трака по длине в локальных координатах кривой: кривизна, «верх», «право» (с креном).
## Словарь: kappa, up, right (PackedVector3Array), length, count
static func bake(curve: Curve3D) -> Dictionary:
	var L := curve.get_baked_length()
	var n := maxi(2, ceili(L / STEP) + 1)
	var kap := PackedVector3Array()
	var ups := PackedVector3Array()
	var rts := PackedVector3Array()
	for i in n:
		var s := L * float(i) / float(n - 1)
		var s0 := maxf(s - HALF_BASE, 0.0)
		var s1 := minf(s + HALF_BASE, L)
		var f0 := TrackMeshBuilder.frame(curve, s0, L)
		var f1 := TrackMeshBuilder.frame(curve, s1, L)
		var fm := TrackMeshBuilder.frame(curve, s, L)
		kap.append((f1.f - f0.f) / maxf(s1 - s0, 0.001))
		ups.append(fm.u)
		rts.append(fm.r)
	return {"kappa": kap, "up": ups, "right": rts, "length": L, "count": n}


## Значения запечённого профиля на расстоянии offset от начала (линейная интерполяция). Словарь: kappa, up, right
static func sample(baked: Dictionary, offset: float) -> Dictionary:
	var n: int = baked.count
	var L: float = baked.length
	var f := clampf(offset / maxf(L, 0.0001), 0.0, 1.0) * float(n - 1)
	var i := mini(int(f), n - 2)
	var t := f - float(i)
	var kap: PackedVector3Array = baked.kappa
	var ups: PackedVector3Array = baked.up
	var rts: PackedVector3Array = baked.right
	return {
		"kappa": kap[i].lerp(kap[i + 1], t),
		"up": ups[i].lerp(ups[i + 1], t).normalized(),
		"right": rts[i].lerp(rts[i + 1], t).normalized(),
	}
