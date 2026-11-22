@tool
class_name JointMath extends RefCounted

###########################
## Математика стыка траков: крен (ATTN_27, шаг C5.4)
###########################
## Чистая математика, без нод. Используется C_Socket при проверке стыка.


## Разница крена на стыке, градусы (0…180). axis: ось стыка, мировое направление «из стоящего трака в стыкуемый»
## (наружный вектор стоящего сокета). up_a, up_b: мировые «верха» поверхности у сокетов двух траков.
## «Верх» проецируется на плоскость, перпендикулярную оси стыка, и меряется угол между проекциями: излом стыка по вертикали
## (разный уклон у соседей, допустимый до joint_kink_max_deg) в разницу не входит, у обычных траков без крена она 0.
## Работает в любую сторону: у трака, повёрнутого на 180°, мировой «верх» тот же, а знак крена относительно хода обратный,
## сравнение мировых векторов это учитывает само
static func bank_diff_deg(axis: Vector3, up_a: Vector3, up_b: Vector3) -> float:
	var a := axis.normalized()
	var pa := up_a - a * a.dot(up_a)
	var pb := up_b - a * a.dot(up_b)
	if pa.length_squared() < 0.000001 or pb.length_squared() < 0.000001:
		return 0.0
	return rad_to_deg(pa.angle_to(pb))


## Оси сонаправлены или противоположны в пределах max_deg градусов (направление не важно, важна линия)
static func axis_aligned(a: Vector3, b: Vector3, max_deg: float) -> bool:
	if a.length_squared() < 0.000001 or b.length_squared() < 0.000001:
		return false
	return absf(a.normalized().dot(b.normalized())) >= cos(deg_to_rad(max_deg))


## Можно ли перейти с конца трака на соседний (ATTN_27, ошибка «Т-стык»): тележка, вылетевшая за конец своего трака,
## принимала ЛЮБОЙ трак под лучом за продолжение пути, в том числе поперечный, и поворачивала на него.
## Теперь нужно два условия, как на настоящем стыке:
##  1) точка въезда gpos рядом (не дальше gap_max) с одним из концов кривой соседа, то есть это его конец, а не середина или бок;
##  2) касательная соседа у этого конца почти вдоль хода (не больше max_deg от оси движения travel_dir, в любую сторону).
## end_a, end_b: мировые положения концов кривой соседа, tan_a, tan_b: мировые касательные у этих концов.
static func can_enter(gpos: Vector3, end_a: Vector3, end_b: Vector3, tan_a: Vector3, tan_b: Vector3,
		travel_dir: Vector3, gap_max: float, max_deg: float) -> bool:
	var da := gpos.distance_to(end_a)
	var db := gpos.distance_to(end_b)
	if minf(da, db) > gap_max:
		return false
	return axis_aligned(travel_dir, tan_a if da <= db else tan_b, max_deg)
