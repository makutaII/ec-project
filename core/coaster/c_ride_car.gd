class_name C_RideCar extends Component

###########################
## Вагон горок: профиль заезда и пинок рукой (ATTN_27 §27.5, §27.8)
###########################
## Висит на вагонах категории coaster_car. Делает три вещи:
##  1. при создании вагона кладёт коэффициент уклона из профиля заезда в шасси (C_Chassis.grade_k);
##  2. пинок рукой: ЛКМ зажать на вагоне (курсор не двигать) и отпустить. Короткий клик только выбирает вагон.
##     Сила растёт с временем удержания (RideProfile), пока идёт зарядка, над вагоном висит надпись с силой.
##     Нажали на корму (заднюю половину) толкаем вперёд носом, на нос (переднюю половину) назад.
## Пинок это то же событие on_train_kicked, что у PgUp и PgDn (SelectTool), поэтому на шасси ничего нового нет.
## Работает и на сошедшем вагоне на столе: событие тогда ловит C_Kinematics (импульс жёсткому телу вдоль носа).
## Числа зарядки (KickCharge) вагон берёт из профиля заезда: клавиши PgUp и PgDn зарядки тоже его используют (on_kick_params).
##  3. сход по нагрузке (ATTN_27 §27.5, шаг C6.1): на траках горок каждый физический кадр считает нормальную и боковую нагрузку
##     (RideDynamics, кривизна трака с учётом крена) и сводит вагон, если нормальная нагрузка упала ниже airtime_min_load
##     (отрыв на горбе, причина «airtime») или боковая выше side_load_max (вылет через борт, причина «side»). Любой сход
##     (в том числе от сцепки или конца трака) записывается в derail_info и печатается в консоль строкой [RIDE].
## Тянуть вагон мышью (драг) можно как раньше: сдвинули курсор дальше CANCEL_PX и зарядка отменяется.
## Клавиши PgUp и PgDn при выбранном вагоне пинают, как у остальных вагонов (SelectTool): короткое нажатие силой kick_short_power,
## зажатие сильнее (та же зарядка и те же числа профиля).

## На сколько пикселей можно сдвинуть курсор при зарядке (дальше это драг, а не пинок)
const CANCEL_PX := 10.0
## Высота плоскости, на которой определяем, в какую половину вагона нажали, над его началом координат
const HAND_HEIGHT := 1.0

## Состояние вагона для сессии заезда: ready (стоит), running (едет), stalled (остановился, не хватило энергии),
## derailed (сошёл). state_changed шлётся при смене
signal state_changed(car: C_RideCar)

const STATE_READY := &"ready"
const STATE_RUNNING := &"running"
const STATE_STALLED := &"stalled"
const STATE_DERAILED := &"derailed"

var state: StringName = STATE_READY
## Причина и обстоятельства схода или остановки: reason, speed, load_n, load_l, track, offset, length (пусто, пока вагон ехал)
var derail_info: Dictionary = {}
## Сколько раз вагон ударился сцепкой сильнее bump_notice_speed (для оценки заезда)
var bumps := 0
## Нагрузки сейчас (в долях g, худшая тележка): нормальная и боковая по модулю
var load_n := 1.0
var load_l := 0.0

var _chassis: C_Chassis
var _bogie: C_Bogie
var _viol_t := 0.0
var _viol_reason := ""
var _stall_t := 0.0
var _last_bump_msec := -100000
var _charging := false
var _charge_t := 0.0
var _press_pos := Vector2.ZERO
var _push_forward := true


func _ready() -> void:
	set_process(false)   # _process нужен только при зарядке


## Все компоненты уже созданы: можно брать шасси
func on_entity_ready() -> void:
	_chassis = get_comp(C_Chassis) as C_Chassis
	_bogie = get_comp(C_Bogie) as C_Bogie
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
	p.short_power = prof.kick_short_power


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


## ---- Сход по нагрузке (RideDynamics) ----

func _physics_process(delta: float) -> void:
	if _chassis == null or _bogie == null:
		return
	if state == STATE_DERAILED:
		if _chassis.is_on_rails:   # вагон снова посадили на трак: начинаем заново
			derail_info = {}
			_viol_t = 0.0
			_viol_reason = ""
			_stall_t = 0.0
			_set_state(STATE_READY)
		return
	if not _chassis.is_on_rails:
		_viol_t = 0.0
		return
	var prof := Coaster.profile()
	var speed := absf(_chassis.current_speed)
	if speed > prof.load_check_min_speed and state != STATE_RUNNING:
		_stall_t = 0.0
		derail_info = {}
		_set_state(STATE_RUNNING)
	# Остановка: уже ехавший вагон стоит дольше stall_time (кроме момента разворота на вершине, он короче)
	if state == STATE_RUNNING:
		if speed < prof.stall_speed:
			_stall_t += delta
			if _stall_t >= prof.stall_time:
				_stall()
		else:
			_stall_t = 0.0
	var worst_n := INF
	var worst_l := 0.0
	var g_eff := RailPhysics.G_ROLL * maxf(_chassis.grade_k, 0.01)
	for b in _bogie.bogies_data:
		if not is_instance_valid(b.current_track):
			continue
		var pc := b.current_track.get_comp(C_Path) as C_RidePath
		if pc == null:
			continue
		var ld := pc.ride_load_at(b.track_distance, speed, g_eff)
		worst_n = minf(worst_n, ld.x)
		worst_l = maxf(worst_l, absf(ld.y))
	if worst_n == INF:
		return   # вагон не на траках горок: нагрузки не считаем
	load_n = worst_n
	load_l = worst_l
	var reason := ""
	if speed > prof.load_check_min_speed:
		if load_n < prof.airtime_min_load:
			reason = "airtime"
		elif load_l > prof.side_load_max:
			reason = "side"
	if reason == "":
		_viol_t = 0.0
		_viol_reason = ""
		return
	if reason != _viol_reason:
		_viol_reason = reason
		_viol_t = 0.0
	_viol_t += delta
	if _viol_t >= prof.derail_hold_time:
		entity.send_event("on_derailed", {
			"reason": reason,
			"current_velocity_3d": _chassis.current_velocity_3d,
		})


## Любой сход вагона (наш по нагрузке, от конца трака, сцепки, препятствия): запоминаем обстоятельства и печатаем
func on_derailed(data: Dictionary) -> void:
	if state == STATE_DERAILED:
		return
	var info := _collect_info(str(data.get("reason", "?")))
	derail_info = info
	print("[RIDE] %s сошёл: %s | v=%.1f | нормальная %.2f g, боковая %.2f g | трак %s, %.1f из %.1f" % [
		entity.name, info.reason, info.speed, info.load_n, info.load_l, info.track, info.offset, info.length])
	LYM.notice.emit(RideReport.message(info))   # обычное уведомление сверху (U: баннер на 3 с)
	_set_state(STATE_DERAILED)


## Мягкий удар сцепки без схода (вагон остался на рельсах): считаем и сообщаем, если сильнее bump_notice_speed.
## Событие получают оба вагона, уведомление не чаще раза в секунду
func on_coupler_impact(data: Dictionary) -> void:
	if bool(data.get("derailed", false)):
		return   # сход уже сообщает on_derailed
	var v := absf(float(data.get("v_close", 0.0)))
	if v < Coaster.profile().bump_notice_speed:
		return
	bumps += 1
	var now := Time.get_ticks_msec()
	if now - _last_bump_msec < 1000:
		return
	_last_bump_msec = now
	print("[RIDE] %s столкновение: v сближения %.1f" % [entity.name, v])
	LYM.notice.emit(RideReport.bump_message(v))


## Остановка: уже ехавший вагон стоит. Состояние stalled, причина в derail_info и в уведомлении
func _stall() -> void:
	var info := _collect_info("stalled")
	derail_info = info
	print("[RIDE] %s остановился | трак %s, %.1f из %.1f" % [entity.name, info.track, info.offset, info.length])
	LYM.notice.emit(RideReport.message(info))
	_set_state(STATE_STALLED)


## Обстоятельства для сообщения: причина, скорость, нагрузки и где (название трака под передней тележкой, расстояние, длина)
func _collect_info(reason: String) -> Dictionary:
	var info := {
		"reason": reason,
		"speed": absf(_chassis.current_speed) if _chassis else 0.0,
		"load_n": load_n,
		"load_l": load_l,
		"track": "",
		"offset": 0.0,
		"length": 0.0,
	}
	if _bogie != null and not _bogie.bogies_data.is_empty():
		var b = _bogie.bogies_data[0]
		if is_instance_valid(b.current_track):
			var idc := b.current_track.get_comp(C_Identity) as C_Identity
			info.track = idc.get_name_e() if idc != null else String(b.current_track.name)
			info.offset = b.track_distance
			var pc := b.current_track.get_comp(C_Path) as C_Path
			if pc != null:
				info.length = pc.curve_of(b.route).get_baked_length()
	return info


func _set_state(new_state: StringName) -> void:
	if state == new_state:
		return
	state = new_state
	state_changed.emit(self)
