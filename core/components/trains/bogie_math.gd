class_name BogieMath extends RefCounted

###################################
## Чистая математика тележек и колёс (без нод). Проверяется tests/bogie_axles_test.gd
###################################


## Вес точки кузова на хорде от первой (передней, меньший z) тележки к последней: 0 на первой, 1 на последней.
## Начало вагона (z = 0 в осях модели, центр кузова по длине) лежит между тележками на расстоянии -z_first от первой при базе z_last - z_first.
## Симметричные тележки дают 0.5: кузов в середине хорды, как было до этого
static func anchor_weight(z_first: float, z_last: float) -> float:
	var base := z_last - z_first
	if absf(base) < 0.001:
		return 0.5
	return -z_first / base


## Крайние оси узла симметричны относительно его центра (центр узла посередине между ними)
static func extremes_symmetric(offsets: PackedFloat32Array, tol := 0.02) -> bool:
	if offsets.size() < 2:
		return true
	var lo := offsets[0]
	var hi := offsets[0]
	for z in offsets:
		lo = minf(lo, z)
		hi = maxf(hi, z)
	return absf(lo + hi) <= tol


## Длина коробки коллизии узла по Z: расстояние между крайними осями плюс радиусы
static func collision_length(half_base: float, radius: float) -> float:
	return (half_base + radius) * 2.0


## Поперечный ход узла: смещение по оси X кузова к точке на рельсе, не дальше допуска
static func clamp_lateral(rel_x: float, play: float) -> float:
	return clampf(rel_x, -play, play)


## Предел курса узла относительно кузова: ограничивает рыскание (вокруг Y), наклон и крен не трогает.
## local_basis это базис узла в осях кузова
static func clamp_yaw(local_basis: Basis, limit_deg: float) -> Basis:
	var e := local_basis.get_euler(EULER_ORDER_YXZ)
	var lim := deg_to_rad(limit_deg)
	if absf(e.y) <= lim:
		return local_basis
	e.y = clampf(e.y, -lim, lim)
	return Basis.from_euler(e, EULER_ORDER_YXZ)


## Фаза в обратную сторону: поза покоя (0) остаётся на месте, цикл идёт назад
static func reverse_phase(phase: float) -> float:
	return fposmod(1.0 - phase, 1.0)


## Фаза колеса 0..1 за оборот по накопленному углу вращения (радианы вокруг +X узла колеса).
## При ходе вперёд угол уменьшается (качение вперёд это отрицательный поворот вокруг +X), фаза при этом растёт
static func wheel_phase(angle: float) -> float:
	return fposmod(-angle / TAU, 1.0)
