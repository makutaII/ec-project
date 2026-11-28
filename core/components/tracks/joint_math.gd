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


## Крен «верха» up у трака, идущего по направлению forward (градусы, + правый край ниже, как RideShape и TrackMeshBuilder.frame).
## Базовый «верх» берётся как у репера без крена: Vector3.UP без составляющей вдоль хода. Крен это угол от базового «верха»
## к up вокруг хода по правой тройке (так репер поворачивает right и up). Нужен flex: он берёт крен соседа у стыка (ATTN_27 §27.15)
static func roll_about(forward: Vector3, up: Vector3) -> float:
	var f := forward.normalized()
	var base := Vector3.UP - f * f.dot(Vector3.UP)
	var u := up - f * f.dot(up)
	if base.length_squared() < 0.000001 or u.length_squared() < 0.000001:
		return 0.0
	return rad_to_deg(base.normalized().signed_angle_to(u.normalized(), f))


## Базис кольца крена на конце трака с ходом t (ATTN_27, C8.3): X это right репера без крена (t × UP), Y это ход (ось кольца),
## Z это «верх» без крена (UP без составляющей вдоль хода). Правая тройка. Если ход строго вертикален, единичный базис
static func ring_basis(t: Vector3) -> Basis:
	var tn := t.normalized()
	var base := Vector3.UP - tn * tn.dot(Vector3.UP)
	if base.length_squared() < 0.000001:
		return Basis.IDENTITY
	return Basis(tn.cross(Vector3.UP).normalized(), tn, base.normalized())


## Крен (градусы, + правый край ниже), на который указывает вектор offset от центра кольца вокруг хода t. offset проецируется на
## плоскость кольца. 0 если вектор вдоль хода или ход вертикален
static func roll_of_point(t: Vector3, offset: Vector3) -> float:
	var tn := t.normalized()
	var base := Vector3.UP - tn * tn.dot(Vector3.UP)
	var v := offset - tn * tn.dot(offset)
	if base.length_squared() < 0.000001 or v.length_squared() < 0.000001:
		return 0.0
	return rad_to_deg(base.normalized().signed_angle_to(v.normalized(), tn))


## Скручивание свободного конца по крену, на который указал курсор: крен конца минус крен начала, приведённое к (−180, 180]
## и округлённое до шага step (5° обычно, 1° с Shift)
static func twist_for(end_roll_deg: float, start_roll_deg: float, step: float) -> float:
	return snappedf(wrapf(end_roll_deg - start_roll_deg, -180.0, 180.0), maxf(step, 0.01))
