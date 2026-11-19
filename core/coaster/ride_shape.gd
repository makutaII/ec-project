@tool
class_name RideShape extends RefCounted

###########################
## Форма трака горок: кривая из уклона, вертикальной дуги и поворота (ATTN_27 §27.4)
###########################
## Чистая математика, без нод. Трак описывается тремя числами вдоль его оси (длина L, мерится по самой кривой):
##  - pitch меняется линейно от pitch_start до pitch_end (угол касательной над горизонтом, + вверх);
##    равные углы это прямой уклон, разные это дуга в вертикальной плоскости (постоянная кривизна);
##  - heading (поворот в плане) растёт линейно от 0 до turn, + вправо: с pitch ≠ 0 получается винтовой участок.
## Кривая начинается в нуле, касательная в начале лежит в вертикальной плоскости, смотрящей в −Z, как у остальных траков
## (C_Path.generate_track_curve). Сокеты берут направление из ручек кривой, поэтому ручки на торцах равны касательной.

## Шаг между точками кривой, ю
const STEP := 1.5
## Подшагов интегрирования на шаг
const SUB := 8


## Единичная касательная при угле pitch над горизонтом и повороте heading вправо от направления −Z
static func tangent(pitch: float, heading: float) -> Vector3:
	return Vector3(cos(pitch) * sin(heading), sin(pitch), -cos(pitch) * cos(heading))


## Кривая трака. turn_deg > 0 вправо. Прямой уклон (pitch равны, turn 0): две точки, ручки нулевые, как у прямых траков
static func build(length: float, pitch_start_deg: float, pitch_end_deg: float, turn_deg: float) -> Curve3D:
	var L := maxf(length, 0.5)
	var th0 := deg_to_rad(pitch_start_deg)
	var th1 := deg_to_rad(pitch_end_deg)
	var turn := deg_to_rad(turn_deg)
	var c := Curve3D.new()
	if absf(th1 - th0) < 0.00001 and absf(turn) < 0.00001:
		c.add_point(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		c.add_point(tangent(th0, 0.0) * L, Vector3.ZERO, Vector3.ZERO)
		return c
	var n := maxi(2, ceili(L / STEP))
	var ds := L / float(n)
	var pos := Vector3.ZERO
	for i in n + 1:
		var t := _tangent_at(ds * i, L, th0, th1, turn)
		var h := t * (ds / 3.0)   # ручки Эрмита → Безье: треть шага вдоль касательной
		c.add_point(pos, -h, h)
		if i < n:
			pos += _segment(ds * i, ds, L, th0, th1, turn)
	return c


## Радиус кривой в плане для физики (C_Path.radius_at), ю. INF у трака без поворота
static func plan_radius(length: float, pitch_start_deg: float, pitch_end_deg: float, turn_deg: float) -> float:
	if absf(turn_deg) < 0.01:
		return INF
	var mid := deg_to_rad((pitch_start_deg + pitch_end_deg) * 0.5)
	return length * cos(mid) / deg_to_rad(absf(turn_deg))


## Трак ровный (оба угла 0): лежит на плоскости, как обычные траки
static func is_level(pitch_start_deg: float, pitch_end_deg: float) -> bool:
	return absf(pitch_start_deg) < 0.01 and absf(pitch_end_deg) < 0.01


static func _tangent_at(s: float, L: float, th0: float, th1: float, turn: float) -> Vector3:
	var k := s / L
	return tangent(lerpf(th0, th1, k), turn * k)


## Смещение за участок [s0, s0 + ds] (интеграл касательной, правило средних)
static func _segment(s0: float, ds: float, L: float, th0: float, th1: float, turn: float) -> Vector3:
	var d := Vector3.ZERO
	var sub := ds / float(SUB)
	for j in SUB:
		d += _tangent_at(s0 + sub * (j + 0.5), L, th0, th1, turn) * sub
	return d
