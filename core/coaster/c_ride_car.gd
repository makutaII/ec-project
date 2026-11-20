class_name C_RideCar extends Component

###########################
## Вагон горок: профиль заезда и пинок рукой (ATTN_27 §27.5, §27.8)
###########################
## Висит на вагонах категории coaster_car. Делает две вещи:
##  1. при создании вагона кладёт коэффициент уклона из профиля заезда в шасси (C_Chassis.grade_k);
##  2. пинок рукой: ЛКМ зажать на вагоне (курсор не двигать) и отпустить. Короткий клик только выбирает вагон.
##     Сила растёт с временем удержания (RideProfile), пока идёт зарядка, над вагоном висит надпись с силой.
##     Нажали на корму (заднюю половину) толкаем вперёд носом, на нос (переднюю половину) назад.
## Пинок это то же событие on_train_kicked, что у PgUp и PgDn (SelectTool), поэтому на шасси ничего нового нет.
## Работает и на сошедшем вагоне на столе: событие тогда ловит C_Kinematics (импульс жёсткому телу вдоль носа).
## Числа зарядки (KickCharge) вагон берёт из профиля заезда: клавиши PgUp и PgDn зарядки тоже его используют (on_kick_params).
## Тянуть вагон мышью (драг) можно как раньше: сдвинули курсор дальше CANCEL_PX и зарядка отменяется.
## Клавиши PgUp и PgDn при выбранном вагоне пинают, как у остальных вагонов (SelectTool): короткое нажатие силой 10,
## зажатие сильнее (та же зарядка и те же числа профиля).

## На сколько пикселей можно сдвинуть курсор при зарядке (дальше это драг, а не пинок)
const CANCEL_PX := 10.0
## Высота плоскости, на которой определяем, в какую половину вагона нажали, над его началом координат
const HAND_HEIGHT := 1.0

var _chassis: C_Chassis
var _charging := false
var _charge_t := 0.0
var _press_pos := Vector2.ZERO
var _push_forward := true


func _ready() -> void:
	set_process(false)   # _process нужен только при зарядке


## Все компоненты уже созданы: можно брать шасси
func on_entity_ready() -> void:
	_chassis = get_comp(C_Chassis) as C_Chassis
	if _chassis == null:
		push_warning("C_RideCar: у вагона нет C_Chassis, профиль заезда не применён")
		return
	_chassis.grade_k = Coaster.profile().grade_k


func _input(event: InputEvent) -> void:
	if not Coaster.is_active() or _chassis == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_try_start_charge(event.position)
		else:
			_finish_charge()
	elif event is InputEventMouseMotion and _charging:
		if _press_pos.distance_to(event.position) > CANCEL_PX:
			_cancel_charge()


func _process(delta: float) -> void:
	if not _charging:
		return
	_charge_t += delta
	_update_label()


func _exit_tree() -> void:
	_cancel_charge()


func _try_start_charge(pos: Vector2) -> void:
	# Вагон под курсором (C_Hovered ставит выбор), на рельсах, не призрак
	if not has_comp(C_Hovered) or has_comp(C_Ghost) : #or not _chassis.is_on_rails:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	# В какую половину вагона нажали: луч мыши, плоскость на высоте руки, локальная Z. Нос смотрит в -Z
	var origin := cam.project_ray_origin(pos)
	var dir := cam.project_ray_normal(pos)
	var plane := Plane(Vector3.UP, entity.global_position.y + HAND_HEIGHT)
	var hit = plane.intersects_ray(origin, dir)
	var local_z := 1.0
	if hit != null:
		local_z = (entity.global_transform.affine_inverse() * (hit as Vector3)).z
	_push_forward = local_z >= 0.0
	_press_pos = pos
	_charge_t = 0.0
	_charging = true
	set_process(true)


func _finish_charge() -> void:
	if not _charging:
		return
	var t := _charge_t
	_cancel_charge()
	var prof := Coaster.profile()
	if t < prof.kick_hold_min:
		return   # короткий клик: только выбор
	var power := _power_at(t)
	entity.send_event("on_train_kicked", {"power_kick": power if _push_forward else -power})


## Сила пинка при удержании t секунд
func _power_at(t: float) -> float:
	var p := KickCharge.defaults()
	on_kick_params(p)
	return KickCharge.power_at(t, p)


## Числа зарядки пинка из профиля заезда. Событие шлёт SelectTool перед зарядкой клавишами PgUp и PgDn
func on_kick_params(p: Dictionary) -> void:
	var prof := Coaster.profile()
	p.hold_min = prof.kick_hold_min
	p.charge_time = prof.kick_charge_time
	p.power_min = prof.kick_power_min
	p.power_max = prof.kick_power_max


func _cancel_charge() -> void:
	_charging = false
	_charge_t = 0.0
	set_process(false)
	InfoTips.clear(self)


## Подсказка с силой у курсора (появляется, когда удержание дольше обычного клика; InfoToolTip, U20a)
func _update_label() -> void:
	if _charge_t < Coaster.profile().kick_hold_min:
		return
	InfoTips.show_lines(self, [InfoTips.title(KickCharge.label_text(_push_forward, _power_at(_charge_t)))])
