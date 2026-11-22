class_name C_Coupler extends ICapability
## Актуальная версия 

####################
## Способность. Живёт на каждом вагоне и локо.
####################
## Сцепка и буфера. У вагона два торца: FRONT (нос, -Z) и REAR (хвост, +Z).
##
## 1. КОНТАКТ торцов есть всегда (буфера): вагоны не проходят друг сквозь друга.
## 2. СЦЕПКА - надстройка над контактом. Если у обоих торцов совместимый механизм
##    и скорость сближения <= couple_speed_max, связь (Link) становится coupled
##    и работает ещё и на растяжение (со слабиной slack).
## 3. УДАР. Если расчётное Δv от удара больше impact_dv_limit - вагон сходит
##    (on_derailed), партнёр получает импульс. Иначе - отскок на буферах.
##
## Сила считается ОДИН раз на пару (владелец - компонент с меньшим instance_id)
## с приоритетом физики -10, то есть ДО C_Chassis. Шасси получает её событием
## on_coupler_force и добавляет к тяге/трению. Скорость напрямую не трогаем.
##
## Пружина задана ЧАСТОТОЙ (omega), а не жёсткостью: k = mu * omega^2, поэтому
## поведение не зависит от масс, а omega дополнительно ограничена шагом физики
## (omega <= 0.3 / dt) - расчёт устойчив при любых массах и составах.
##
## 4. ПРЕПЯТСТВИЯ ПО ХОДУ (13.1.6). Вагон на рельсах едет кинематически, физика его не останавливает, поэтому
##    каждый тик он "пробует" путь перед собой телом вагона (cast_motion). Препятствие: вагон не на рельсах
##    (сошедший, брошенный), опора эстакады, низко висящий чужой трак. Реакция как у удара сцепки: Δv по массам,
##    больше impact_dv_limit - сход, иначе отскок. Стоящий вагон получает импульс (его толкает).
##
## События наружу (для звука/анимации/InfoPanel):
##   on_coupled          {other, end, v_close}
##   on_coupler_impact   {v_close, dv, derailed}
##   on_coupler_broken   {force}
##   on_coupler_released {reason}

const FRONT := 0
const REAR := 1

const GROUP := &"coupler"
## Тип сцепки «вечная» (сочленённый блок: паровоз с тендером, секции электровоза, вагоны скоростного).
## Цепляется только с таким же типом, после сцепки не рвётся и не расцепляется вручную. Люфт и ход буфера
## остаются из настроек вагона (slack, buffer_travel)
const FIXED := &"fixed"
const SCAN_PERIOD := 0.1   # с,  как часто обновляем список соседей
const SCAN_MARGIN := 6.0   # м,  запас радиуса поиска соседей
const MAX_OVERLAP := 2.0   # м,  глубже - считаем, что вагоны друг друга не касаются
const RELEASE_GAP := 0.05  # м,  несцепленный контакт отпускаем при таком зазоре
const BUMP_SPEED := 0.3    # м/с, ниже - событие "стук" не шлём

# XX claude-terra 13.1.6
const PROBE_LOOKAHEAD := 0.05    # м, запас перед касанием сверх пути за тик
const PROBE_SHRINK := Vector3(0.2, 0.3, 0.0)   # на сколько кузов "сжат" (ширина, высота снизу, длина): свои рельсы не цепляем
const PROBE_CHAIN_DEPTH := 4     # сколько траков вперед и назад от тележек не считаем препятствием (свой путь)
const PROBE_LAYERS := ['ground', 'tracks', 'trains', 'supports', 'room']   # твёрдые слои, которые вагон на рельсах считает препятствием
const PROBE_COOLDOWN := 0.15     # с, пауза после удара
const PROBE_MIN_SPEED := 0.05    # м/с, медленнее - не проверяем

# --- Заполняются CouplerSetting из WagonConfig ---
var offset_z: float = 8.0                 # от центра вагона до торца (сцепки), м
var type_front: StringName = &"nem"       # "" - механизма нет (буфер остаётся)
var type_rear: StringName = &"nem"
var slack: float = 0.15                   # свободный ход сцепки, м
var buffer_travel: float = 0.10           # ход буфера до упора, м
var strength: float = 600.0                # сила разрыва сцепки, Н
var couple_speed_max: float = 1.5         # макс. скорость сближения, при которой сцепляемся, м/с
var impact_dv_limit: float = 3.0          # Δv от удара, после которого вагон сходит, м/с

# --- Настройка "ощущения" (в сеттинг не выносим, пока не понадобится) ---
var omega: float = 12.0                   # частота буфера/сцепки, рад/с
var buffer_zeta: float = 0.25             # демпфирование буфера (0.25 -> отскок ~0.44)
var draw_zeta: float = 0.5                # демпфирование сцепки на растяжении
var hard_stop_mult: float = 6.0           # во сколько раз жёстче упор буфера
var lateral_tol: float = 1.0              # допуск по боковому смещению торцов, м
var align_cos: float = 0.8                # торцы должны смотреть друг на друга (cos угла)


## Связь между двумя торцами. Один объект лежит в links[] у обоих вагонов.
class Link:
	var a: C_Coupler        # ВЛАДЕЛЕЦ (меньший instance_id) - он считает силы
	var a_end: int
	var b: C_Coupler
	var b_end: int
	var coupled := false    # false - просто контакт буферов
	var permanent := false  # вечная сцепка (тип FIXED на обоих торцах): не рвётся, ручная расцепка не работает; люфт из настроек
	var stretch := 0.0      # дебаг: зазор s (<0 - сжатие)
	var force := 0.0        # дебаг: сила на B вдоль нормали A (>0 толкает, <0 тянет)
	var peak := 0.0

	func other(me: C_Coupler) -> C_Coupler:
		return b if me == a else a


var links: Array = [null, null]          # [FRONT, REAR] -> Link или null
var _neighbors: Array[C_Coupler] = []
var _scan_timer := 0.0
# XX claude-terra 13.1.6: препятствия по ходу
var _probe_dir := 0.0                        # знак последнего хода: направление пробы, когда вагон стоит у стены
var _probe_shape: BoxShape3D                 # тело вагона, чуть меньше настоящего (см. PROBE_SHRINK)
var _probe_exclude: Array[RID] = []          # свое тело, вагоны на рельсах, цепочка траков под вагоном
var _probe_tracks := {}                      # те же траки как Entity (на случай, если RID не добрали)
var _probe_cd := 0.0                         # после удара не реагируем на то же препятствие
var _saved_coupled: Array = [false, false]


func _init() -> void:
	process_physics_priority = -10       # раньше C_Chassis (0)


func on_added() -> void:
	add_to_group(GROUP)
	_scan_timer = randf() * SCAN_PERIOD  # разносим сканы разных вагонов по кадрам


func on_removed() -> void:
	_drop_all(&"removed")


func _exit_tree() -> void:
	_drop_all(&"removed")


# ==========================================
# ПУБЛИЧНЫЙ API
# ==========================================

func can_couple(end: int) -> bool:
	return _type_of(end) != &""


## Сцепляет торцы без сближения (состав из шаблона ставится уже стоящим вплотную).
## false: типы сцепок несовместимы или торец занят
func couple_with(end: int, other: C_Coupler, oend: int) -> bool:
	if not _compatible(end, other, oend):
		return false
	if links[end] != null or other.links[oend] != null:
		return false
	_link(end, other, oend, true)
	entity.send_event("on_coupled", {"other": other.entity, "end": end, "v_close": 0.0})
	other.entity.send_event("on_coupled", {"other": entity, "end": oend, "v_close": 0.0})
	return true


func is_coupled(end: int) -> bool:
	var l: Link = links[end]
	return l != null and l.coupled


## Сосед по сцепке (или null)
func get_neighbor(end: int) -> C_Coupler:
	var l: Link = links[end]
	if l and l.coupled:
		return l.other(self)
	return null


## Ручная расцепка (для инструмента/кнопки в InfoPanel)
## Вечную сцепку вручную не разорвать (false). Сход, снятие с рельсов и удаление её рвут как обычно
func uncouple(end: int) -> bool:
	var l: Link = links[end]
	if l == null:
		return true
	if l.permanent:
		return false
	_drop_link(l, &"manual")
	return true


func is_permanent(end: int) -> bool:
	var l: Link = links[end]
	return l != null and l.coupled and l.permanent


## Весь состав, в котором стоит этот вагон (обход по сцепкам)
func get_consist() -> Array[Entity]:
	var result: Array[Entity] = []
	var seen := {}
	var queue: Array[C_Coupler] = [self]
	while queue.size() > 0:
		var c: C_Coupler = queue.pop_front()
		if seen.has(c):
			continue
		seen[c] = true
		result.append(c.entity)
		for end in 2:
			var l: Link = c.links[end]
			if l and l.coupled:
				queue.append(l.other(c))
	return result


## Состав по порядку от головной части. Головная: крайняя в сторону FRONT выбранного вагона.
## Элемент: {"entity": Entity, "reversed": bool}; reversed - часть повёрнута передом назад относительно
## направления записи (в неё вошли через торец REAR). Нужна шаблонам составов (ConsistTemplate).
## only_permanent: идти только по вечным сцепкам (группа, которая ездит, тащится и удаляется целиком)
func get_ordered_consist(only_permanent := false) -> Array[Dictionary]:
	# 1. От этого вагона вперёд до головной части
	var cur: C_Coupler = self
	var out_end := FRONT
	var head_exit := REAR   # торец головной части, которым она сцеплена со следующей
	var seen := {self: true}
	while true:
		var l: Link = cur.links[out_end]
		if l == null or not l.coupled or (only_permanent and not l.permanent):
			break
		var nxt := l.other(cur)
		if seen.has(nxt):
			break
		seen[nxt] = true
		var e := nxt._end_of(l)
		cur = nxt
		out_end = 1 - e
		head_exit = e
	# 2. От головной части назад по цепочке
	var result: Array[Dictionary] = []
	var visited := {}
	var entered := 1 - head_exit
	var exit_end := head_exit
	while true:
		visited[cur] = true
		result.append({"entity": cur.entity, "reversed": entered == REAR})
		var l2: Link = cur.links[exit_end]
		if l2 == null or not l2.coupled or (only_permanent and not l2.permanent):
			break
		var nxt2 := l2.other(cur)
		if visited.has(nxt2):
			break
		var e2 := nxt2._end_of(l2)
		cur = nxt2
		entered = e2
		exit_end = 1 - e2
	return result


## Каким торцом этой сцепки держится связь
func _end_of(l: Link) -> int:
	return FRONT if links[FRONT] == l else REAR


## Статус торца для вкладки «Сведения» в InfoPanel: нет / контакт / сцеплен / вечная и имя соседа
func end_status(end: int) -> String:
	var l: Link = links[end]
	if l == null:
		return "нет"
	var other_name := str(l.other(self).entity.name)
	if not l.coupled:
		return "контакт: " + other_name
	return ("вечная: " if l.permanent else "сцеплен: ") + other_name


## Строки для отладочного вывода (в InfoPanel не используется, там end_status)
func get_debug_info() -> Array[String]:
	var res: Array[String] = []
	for end in 2:
		var title := "front" if end == FRONT else "rear"
		var l: Link = links[end]
		if l == null:
			res.append("%s: free" % title)
		else:
			res.append("%s: %s [%s] s=%.2f F=%.1f peak=%.1f" % [
				title, ("PERMANENT" if l.permanent else "COUPLED") if l.coupled else "contact",
				l.other(self).entity.name, l.stretch, l.force, l.peak])
	return res


# ==========================================
# СОБЫТИЯ ENTITY
# ==========================================

## Игрок схватил вагон - он отцепляется (состав целиком не тащим)
## Схватили вагон: связи рвём, кроме сцепок внутри перетаскиваемой группы (DragTool)
func on_drag_started(_data: Dictionary) -> void:
	_drop_loose(&"drag")


## Сход: связи рвём. Дальше физику между сошедшим и остальными ведёт Godot (RigidBody)
func on_derailed(_data: Dictionary) -> void:
	_drop_all(&"derailed")


# ==========================================
# ФИЗИЧЕСКИЙ ЦИКЛ
# ==========================================

func _physics_process(delta: float) -> void:
	if delta <= 0.0:
		return

	var ch := _chassis()
	if not ch or not ch.is_on_rails:
		if links[FRONT] or links[REAR]:
			_drop_loose(&"off_rails")
		return

	_refresh_neighbors(delta, ch)

	# XX claude-terra 13.1.6: препятствия по ходу
	_probe_cd = maxf(_probe_cd - delta, 0.0)
	if Global.rail_obstacles:
		_probe_obstacles(delta, ch)

	# 1. Новые контакты на свободных торцах
	for end in 2:
		if links[end] == null:
			_detect_contact(end, ch)

	# 2. Силы по связям, где я владелец
	for end in 2:
		var l: Link = links[end]
		if l and l.a == self and l.a_end == end:
			_solve_link(l, delta)


## Раз в SCAN_PERIOD собираем вагоны поблизости (грубая отсечка, чтобы не гонять N^2 каждый кадр)
func _refresh_neighbors(delta: float, ch: C_Chassis) -> void:
	_scan_timer -= delta
	if _scan_timer > 0.0:
		return
	_scan_timer = SCAN_PERIOD
	_neighbors.clear()

	var my_pos := entity.global_position
	for node in get_tree().get_nodes_in_group(GROUP):
		var other := node as C_Coupler
		if other == null or other == self or not is_instance_valid(other.entity):
			continue
		var och := other._chassis()
		var v_sum := absf(ch.current_speed) + (absf(och.current_speed) if och else 0.0)
		var reach := offset_z + other.offset_z + SCAN_MARGIN + 2.0 * SCAN_PERIOD * v_sum
		if my_pos.distance_squared_to(other.entity.global_position) <= reach * reach:
			_neighbors.append(other)
	_rebuild_probe_exclude()   # XX claude-terra 13.1.6


## Ищем контакт моего свободного торца с торцом соседа. Пару ведёт тот, у кого меньше id.
func _detect_contact(end: int, ch: C_Chassis) -> void:
	var p := _end_pos(end)
	var n := _end_normal(end)
	var my_id := get_instance_id()

	for other in _neighbors:
		if not is_instance_valid(other) or other.get_instance_id() < my_id:
			continue
		var och := other._chassis()
		if not och or not och.is_on_rails:
			continue

		for oend in 2:
			if other.links[oend] != null:
				continue
			# Торцы должны смотреть друг на друга (отсекает параллельные пути и стрелки)
			if n.dot(other._end_normal(oend)) > -align_cos:
				continue
			var d := other._end_pos(oend) - p
			var s := d.dot(n)                       # зазор вдоль оси A (<=0 - касание)
			if s > 0.0 or s < -MAX_OVERLAP:
				continue
			if (d - n * s).length() > lateral_tol:  # соседний путь / не в ось
				continue
			_on_first_contact(end, ch, other, oend, och)
			return


## Первый кадр касания: сцепились, отскочили или разбились
func _on_first_contact(end: int, ch: C_Chassis, other: C_Coupler, oend: int, och: C_Chassis) -> void:
	var n := _end_normal(end)                       # из A в сторону B
	var ax_a = ch.get_motion_axis()
	var ax_b = och.get_motion_axis()
	# Скорость сближения. Оси движения считаем в мировых векторах: знак current_speed
	# у вагонов на разных контурах/траках может быть привязан к разным направлениям.
	var v_close = (ax_a * ch.current_speed - ax_b * och.current_speed).dot(n)

	var ma := _mass()
	var mb := other._mass()
	var mu := ma * mb / (ma + mb)

	# --- Удар слишком сильный ---
	if v_close > 0.0:
		var k = (1.0 + _restitution(buffer_zeta)) * mu * v_close
		var dv_a = k / ma
		var dv_b = k / mb
		var crash_a = dv_a > impact_dv_limit
		var crash_b = dv_b > other.impact_dv_limit
		if crash_a or crash_b:
			_crash(ch, ax_a, -n, dv_a, crash_a, v_close)
			other._crash(och, ax_b, n, dv_b, crash_b, v_close)
			return

	# --- Контакт: сцепка или отскок на буферах ---
	var can = _compatible(end, other, oend) \
			and v_close <= minf(couple_speed_max, other.couple_speed_max)
	_link(end, other, oend, can)

	if can:
		entity.send_event("on_coupled", {"other": other.entity, "end": end, "v_close": v_close})
		other.entity.send_event("on_coupled", {"other": entity, "end": oend, "v_close": v_close})
	elif v_close > BUMP_SPEED:
		entity.send_event("on_coupler_impact", {"v_close": v_close, "dv": 0.0, "derailed": false})
		other.entity.send_event("on_coupler_impact", {"v_close": v_close, "dv": 0.0, "derailed": false})


## Реакция вагона на удар. push_dir - куда летит этот вагон (A - назад от B, B - вперёд).
func _crash(ch: C_Chassis, axis: Vector3, push_dir: Vector3, dv: float, derail: bool, v_close: float) -> void:
	if derail:
		entity.send_event("on_derailed", {
			"reason": "coupler_impact",
			"current_velocity_3d": axis * ch.current_speed + push_dir * dv,
		})
	else:
		# Остаёмся на рельсах: Δv отдаём шасси импульсом (Н*с), оно переведёт в скорость
		entity.send_event("on_impulse", {"impulse": _mass() * dv * push_dir.dot(axis)})
	entity.send_event("on_coupler_impact", {"v_close": v_close, "dv": dv, "derailed": derail})


## Силы по связи. Вызывает владелец пары.
func _solve_link(l: Link, dt: float) -> void:
	var cb := l.b
	if not is_instance_valid(cb) or not is_instance_valid(cb.entity):
		_drop_link(l, &"partner_gone")
		return
	var ch_a := _chassis()
	var ch_b := cb._chassis()
	if l.coupled and _pair_dragging(l):
		return   # группу тащат: связь ждёт посадки на рельсы
	if not ch_a or not ch_b or not ch_b.is_on_rails:
		_drop_link(l, &"partner_off_rails")
		return

	var n := _end_normal(l.a_end)                   # ось сцепки, из A в B
	var d := cb._end_pos(l.b_end) - _end_pos(l.a_end)
	var s := d.dot(n)                               # <0 сжатие буферов, >slack растяжение
	l.stretch = s

	# Связь потеряла смысл: торцы разошлись в стороны (стрелка, разные пути)
	if (d - n * s).length() > lateral_tol * 2.0:
		_drop_link(l, &"misaligned")
		return
	# Несцепленный контакт закончился
	if not l.coupled and s > RELEASE_GAP:
		_drop_link(l, &"separated")
		return

	var ax_a = ch_a.get_motion_axis()
	var ax_b = ch_b.get_motion_axis()
	var sdot = (ax_b * ch_b.current_speed - ax_a * ch_a.current_speed).dot(n)  # >0 - расходятся

	var ma := _mass()
	var mb := cb._mass()
	var mu := ma * mb / (ma + mb)
	var w := minf(minf(omega, cb.omega), 0.3 / dt)  # устойчивость при любых массах и dt
	var slk := 0.5 * (slack + cb.slack)
	var trv := 0.5 * (buffer_travel + cb.buffer_travel)

	# f - сила на B вдоль +n: f>0 - буфера толкают, f<0 - сцепка тянет
	var f := 0.0
	if s < 0.0:
		var x := minf(-s, trv * 3.0)                # ограничиваем, чтобы дроп "внахлёст" не взрывал вагоны
		var push = mu * (w * w * x - 2.0 * buffer_zeta * w * sdot)
		if x > trv:
			push += mu * w * w * hard_stop_mult * (x - trv)   # упор буфера
		f = maxf(push, 0.0)
	elif l.coupled and s > slk:
		var x := s - slk                            # слабину выбрали - сцепка натянулась
		var pull = mu * (w * w * x + 2.0 * draw_zeta * w * sdot)
		f = -maxf(pull, 0.0)
		if not l.permanent and -f > minf(strength, cb.strength):
			_break(l, -f)
			return

	l.force = f
	l.peak = maxf(l.peak, absf(f))
	if f != 0.0:
		# Проекция на ось движения каждого вагона: в кривой часть силы уходит в рельсы
		entity.send_event("on_coupler_force", {"force": (-n * f).dot(ax_a)})
		cb.entity.send_event("on_coupler_force", {"force": (n * f).dot(ax_b)})


# ==========================================
# ПРЕПЯТСТВИЯ ПО ХОДУ (13.1.6)
# ==========================================

## Что не считаем препятствием: свое тело, вагоны на рельсах (их контакты ведут сцепки, они кинематические),
## цепочка траков под вагоном (свои рельсы и балласт). Обновляем вместе со списком соседей
func _rebuild_probe_exclude() -> void:
	var ex: Array[RID] = []
	var k := entity.get_comp(C_Kinematics) as C_Kinematics
	if k and is_instance_valid(k.rb):
		ex.append(k.rb.get_rid())
	for other in _neighbors:
		if not is_instance_valid(other) or not is_instance_valid(other.entity):
			continue
		var och := other._chassis()
		var ok := other.entity.get_comp(C_Kinematics) as C_Kinematics
		if och and och.is_on_rails and ok and is_instance_valid(ok.rb):
			ex.append(ok.rb.get_rid())

	var seen := {}
	var frontier: Array[Entity] = []
	var bc := entity.get_comp(C_Bogie) as C_Bogie
	if bc:
		for b in bc.bogies_data:
			if is_instance_valid(b.current_track):
				frontier.append(b.current_track)
	for _depth in PROBE_CHAIN_DEPTH:
		var next: Array[Entity] = []
		for t in frontier:
			if seen.has(t) or not is_instance_valid(t):
				continue
			seen[t] = true
			var p := t.get_comp(C_Path) as C_Path
			if p:
				if is_instance_valid(p.ballast_node):
					ex.append(p.ballast_node.get_rid())
				if is_instance_valid(p.head_node):
					ex.append(p.head_node.get_rid())
			var sock := t.get_comp(C_Socket) as C_Socket
			if sock:
				next.append_array(sock.get_connected_entities())
		frontier = next
	_probe_exclude = ex
	_probe_tracks = seen


## Тело вагона для пробы: копия коробки вагона, сжатая по PROBE_SHRINK. Нижняя грань поднята, верх и перед на месте
func _get_probe_shape(node: CollisionShape3D) -> BoxShape3D:
	var src := node.shape as BoxShape3D
	if src == null:
		return null
	if _probe_shape == null:
		_probe_shape = BoxShape3D.new()
	_probe_shape.size = (src.size - PROBE_SHRINK).max(Vector3(0.1, 0.1, 0.1))
	return _probe_shape


## Проба пути на этот тик: тело вагона едет по оси движения на |v| * dt + запас. Касание - удар
func _probe_obstacles(delta: float, ch: C_Chassis) -> void:
	var v := ch.current_speed
	# на малой скорости (и при постоянной тяге у стены) направление берем с прошлого тика, иначе стена пропускает
	var dir := signf(v) if absf(v) >= PROBE_MIN_SPEED else _probe_dir
	if absf(v) >= PROBE_MIN_SPEED:
		_probe_dir = dir
	if dir == 0.0:
		return
	var k := entity.get_comp(C_Kinematics) as C_Kinematics
	if k == null or not is_instance_valid(k.rb) or not k.rb.is_inside_tree():
		return
	var node := k.rb.get_node_or_null("WagonCollisionShape3D") as CollisionShape3D
	if node == null:
		return
	var shape := _get_probe_shape(node)
	if shape == null:
		return

	var n := ch.get_motion_axis() * dir            # куда едем (мир)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	# коробка сжата снизу и с боков: центр сдвигаем вверх на половину сжатия по высоте, верх и перед не трогаем
	params.transform = node.global_transform * Transform3D(Basis.IDENTITY, Vector3(0.0, PROBE_SHRINK.y * 0.5, 0.0))
	params.motion = n * (maxf(v * dir, 0.0) * delta + PROBE_LOOKAHEAD)
	# 13.2: проба смотрит ВСЕ твёрдые слои (раньше список был коротким, и лист пенопласта 'ground' и комната 'room'
	# вагон не замечал). Не смотрим только служебные: sockets, handles, ghost. Новый твёрдый слой добавлять сюда
	params.collision_mask = Global.active_layers(PROBE_LAYERS)
	params.collide_with_bodies = true
	params.collide_with_areas = true               # балласт трака это Area3D
	params.exclude = _probe_exclude

	var space := k.rb.get_world_3d().direct_space_state
	var res := space.cast_motion(params)
	if res.size() < 2 or res[1] >= 1.0:
		return

	# где уперлись: смещаем тело в точку касания и спрашиваем, с чем пересекается
	params.transform.origin += params.motion * res[1]
	params.motion = Vector3.ZERO
	var hits := space.intersect_shape(params, 8)
	var best: Object = null
	for h in hits:
		var c: Object = h.get("collider")
		if c == null:
			continue
		var e := _entity_of(c)
		if e == entity:
			continue
		if e and _probe_tracks.has(e):
			continue                               # свой путь
		var och := (e.get_comp(C_Chassis) as C_Chassis) if e else null
		if och and och.is_on_rails:
			continue                               # вагон на рельсах: это дело сцепок
		if best == null or (c is RigidBody3D and not (best is RigidBody3D)):
			best = c                               # движущийся предмет (вагон) важнее неподвижного
	if best == null:
		return
	_on_obstacle_hit(ch, n, best)


## Удар о препятствие. Масса неподвижного = бесконечность (mu = ma). Формулы те же, что в _on_first_contact
func _on_obstacle_hit(ch: C_Chassis, n: Vector3, obstacle: Object) -> void:
	var e := _entity_of(obstacle)
	var rb2 := obstacle as RigidBody3D
	var ma := _mass()
	var mb := INF
	var vb := Vector3.ZERO
	if rb2:
		mb = maxf(rb2.mass, 0.01)
		vb = rb2.linear_velocity
	var v_fwd := ch.current_speed * n.dot(ch.get_motion_axis())   # скорость вдоль n (может быть <= 0 у стены)
	# неподвижное препятствие (колонна, трак): стена. Тяга не должна проталкивать вагон сквозь, гасим ход в его сторону
	if rb2 == null and v_fwd > 0.0:
		ch.current_speed = 0.0
	var v_close := v_fwd - vb.dot(n)                      # скорость сближения вдоль хода
	if v_close <= 0.02 or _probe_cd > 0.0:
		return                                            # уходит быстрее нас, касание без удара или пауза после удара

	var mu := ma if is_inf(mb) else ma * mb / (ma + mb)
	var k := (1.0 + _restitution(buffer_zeta)) * mu * v_close
	var dv_a := k / ma
	var dv_b := 0.0 if is_inf(mb) else k / mb
	var derail := dv_a > impact_dv_limit
	_probe_cd = PROBE_COOLDOWN

	# получатель удара: стоящий вагон толкаем (импульс по ходу), он сам решает, что делать дальше
	if rb2:
		rb2.sleeping = false
		rb2.apply_central_impulse(n * k)
		if e:
			e.send_event("on_coupler_impact", {"v_close": v_close, "dv": dv_b, "derailed": false})

	# мы: сход или отскок. Скорость после удара вдоль n: |v| - dv_a (отрицательная - летим назад)
	var axis := ch.get_motion_axis()
	if derail:
		entity.send_event("on_derailed", {
			"reason": "obstacle",
			"current_velocity_3d": n * (absf(ch.current_speed) - dv_a),
		})
	else:
		entity.send_event("on_impulse", {"impulse": ma * dv_a * (-n).dot(axis)})
	entity.send_event("on_coupler_impact", {"v_close": v_close, "dv": dv_a, "derailed": derail, "obstacle": true})


func _entity_of(node: Object) -> Entity:
	var cur := node as Node
	while cur:
		if cur is Entity:
			return cur
		cur = cur.get_parent()
	return null


# ==========================================
# СВЯЗИ
# ==========================================

func _link(end: int, other: C_Coupler, oend: int, coupled: bool) -> Link:
	var l := Link.new()
	if get_instance_id() < other.get_instance_id():
		l.a = self
		l.a_end = end
		l.b = other
		l.b_end = oend
	else:
		l.a = other
		l.a_end = oend
		l.b = self
		l.b_end = end
	l.coupled = coupled
	l.permanent = coupled and _type_of(end) == FIXED and other._type_of(oend) == FIXED
	links[end] = l
	other.links[oend] = l
	return l


func _drop_link(l: Link, reason: StringName) -> void:
	if l == null:
		return
	for c in [l.a, l.b]:
		if not is_instance_valid(c):
			continue
		var end: int = l.a_end if c == l.a else l.b_end
		if c.links[end] == l:
			c.links[end] = null
		if l.coupled and is_instance_valid(c.entity) and c.entity.is_inside_tree():
			c.entity.send_event("on_coupler_released", {"reason": reason})


## Рвёт все связи, кроме сцепок внутри перетаскиваемой группы (групповое перетаскивание, DragTool)
func _drop_loose(reason: StringName) -> void:
	for end in 2:
		var l: Link = links[end]
		if l and not (l.coupled and _pair_dragging(l)):
			_drop_link(l, reason)


## Оба торца связи в драге: это одна перетаскиваемая группа (вечная связка или состав из шаблона).
## Одиночный драг вагона дает C_Drag только ему, поэтому его сцепки рвутся как раньше
func _pair_dragging(l: Link) -> bool:
	return l.a.entity.has_comp(C_Drag) and l.b.entity.has_comp(C_Drag)


## Вагоны, связанные с этим вечными сцепками (включая его), по порядку от головной
func get_permanent_group() -> Array[Entity]:
	var out: Array[Entity] = []
	for item in get_ordered_consist(true):
		out.append(item["entity"])
	return out


func _drop_all(reason: StringName) -> void:
	for end in 2:
		var l: Link = links[end]
		if l:
			_drop_link(l, reason)


func _break(l: Link, force: float) -> void:
	var ea := l.a.entity
	var eb := l.b.entity
	_drop_link(l, &"overload")
	ea.send_event("on_coupler_broken", {"force": force})
	eb.send_event("on_coupler_broken", {"force": force})


# ==========================================
# ГЕОМЕТРИЯ / ХЕЛПЕРЫ
# ==========================================

## Мировая позиция торца (по хорде вагона, без подвески)
func _end_pos(end: int) -> Vector3:
	var z := -offset_z if end == FRONT else offset_z
	return entity.global_transform * Vector3(0.0, 0.0, z)


## Наружная нормаль торца: нос смотрит в -Z вагона, хвост в +Z
func _end_normal(end: int) -> Vector3:
	var fwd := -entity.global_basis.z
	return fwd if end == FRONT else -fwd


func _type_of(end: int) -> StringName:
	return type_front if end == FRONT else type_rear


func _compatible(end: int, other: C_Coupler, oend: int) -> bool:
	return can_couple(end) and other.can_couple(oend) and _type_of(end) == other._type_of(oend)


func _chassis() -> C_Chassis:
	return entity.get_comp(C_Chassis) as C_Chassis


func _mass() -> float:
	var k := entity.get_comp(C_Kinematics) as C_Kinematics
	return maxf(k.mass, 0.01) if k else 1.0


## Коэффициент восстановления для затухающего осциллятора
func _restitution(zeta: float) -> float:
	return exp(-PI * zeta / sqrt(1.0 - zeta * zeta))


# ==========================================
# SAVE / LOAD
# ==========================================

func save_data() -> Dictionary:
	return {
		'comp_path': get_script().resource_path,
		'comp_name': get_script().resource_path.get_file().get_basename(),
		'coupled': [is_coupled(FRONT), is_coupled(REAR)],
	}


func load_data(_data: Dictionary) -> void:
	_saved_coupled = _data.get('coupled', [false, false])


## SaveManager вызывает ПОСЛЕ того, как все объекты расставлены и у шасси отработал
## restore_snap_after_load (нужен is_on_rails и финальные transform).
func restore_links_after_load() -> void:
	for end in 2:
		if _saved_coupled[end] and links[end] == null:
			_restore_end(end)


## Остались сцепки из сейва, которые еще не удалось восстановить (SaveManager повторяет попытки)
func has_unrestored_links() -> bool:
	for end in 2:
		if _saved_coupled[end] and links[end] == null:
			return true
	return false


func _restore_end(end: int) -> void:
	var p := _end_pos(end)
	for node in get_tree().get_nodes_in_group(GROUP):
		var other := node as C_Coupler
		if other == null or other == self:
			continue
		for oend in 2:
			if other.links[oend] == null and _compatible(end, other, oend) \
					and p.distance_to(other._end_pos(oend)) <= slack + 0.5:
				_link(end, other, oend, true)
				return
