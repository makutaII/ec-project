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


## Фаза колеса 0..1 за оборот по накопленному углу вращения (радианы вокруг +X узла колеса).
## При ходе вперёд угол уменьшается (качение вперёд это отрицательный поворот вокруг +X), фаза при этом растёт
static func wheel_phase(angle: float) -> float:
	return fposmod(-angle / TAU, 1.0)
