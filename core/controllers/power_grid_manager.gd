extends Node
# class_name PowerGridManager название класса отменяем, так как теперь это синглтон PGM
###########################
##💡 PGM - Системный сервис(autoload), контроль енергосети (фасад DCS)
############################
##
## Пульт (2D панель или 3D сущность) это устройство ввода: он владеет `PowerSource` и шлёт команды `set_command`.
## PGM хранит источники, питающую сеть, порты потребителей, считает цепи (RailNetBuilder, D1) и нагрузку (PowerSolver, D3).
##
## D2 (ATTN_10): состояние пульта живёт в `PowerSource` и `PowerOutput`; метка вывода это номер цепи у фидеров.
## `power_pwm` остался производным представлением для сторонних читателей (тесты): {"voltage": команда, "is_stopped": стоп или защита}.
## Напряжение на рельсах: `get_power(метка)`, состояние вывода: `get_output(метка)`.
## D3: решатель нагрузки с шагом 10 Гц, защита (перегрузка, КЗ), питающая сеть `mains`, порты `PowerPort`.

## Политика конфликта фидеров с разными выводами в одной цепи (ATTN_10 §10.5.4, Q7)
enum ConflictPolicy { MERGE, TRIP }

## Шаг решателя нагрузки, с
const SOLVER_STEP := 0.1

## Источники питания (пульты). Один свободный `multi` создаётся на старте, панель забирает его (register_source)
var sources: Array[PowerSource] = []
## Питающая сеть макета (розетка). Источники с `needs_supply` без неё мертвы
var mains := PowerSupply.new()
## Порты потребителей (моторы локо)
var ports: Array[PowerPort] = []
## MERGE: ведёт фидер с наименьшим номером, остальные подсвечены. TRIP: конфликт отключает оба вывода (правила режима D7)
var conflict_policy: ConflictPolicy = ConflictPolicy.MERGE
## Физическая проводка обязательна (D4): клип без провода до вывода обесточен. false: клип без провода питает по метке
## (виртуальная проводка), клип с проводом питается по проводу
var wiring_required := false
## Свет вагонов нагружает вывод (правило режима D7, по умолчанию нет)
var load_for_lights := false
## Шина аксессуаров 12 В (D6): свет домов и фонарей, привод стрелок. Один на макет
var bus := AccessoryBus.new()
## Сущность трака -> корень связного участка (после последнего пересчёта, для датчиков занятости)
var _track_roots: Dictionary = {}
## Корень участка -> занят (прошлый шаг), для событий net_occupied
var _occupied_prev: Dictionary = {}
## Правила электрики макета (D7). Меняются через apply_rules, пишутся в сейв
var rules: DCSRules = DCSPresets.make(DCSPresets.STANDARD)
## Метка -> время срабатывания защиты, мс (автосброс при ShortProtection.AUTO)
var _trip_at: Dictionary = {}

## Производное представление (метка -> {"voltage": команда, "is_stopped": стоп или защита}). Источник правды это PowerOutput
var power_pwm : Dictionary = {}

# Список всех активных КЛИПОВ на столе
var active_clips: Array[C_PowerClip] = []

# Флаг включения визуального повер-слоя
var is_power_layer_active: bool = false

# флаг ожидания пересчета сети
var _recalc_pending: bool = false

## Строит граф цепей (хранит список виденных траков между пересчетами)
var _builder := RailNetBuilder.new()
var _solver := PowerSolver.new()
var _solver_acc := 0.0
var _next_source_id := 1
## метка -> [источник, вывод]
var _label_index: Dictionary = {}

## Сводка по цепям после последнего пересчета: net_id -> {feeders, tracks, conflicts, short}
var net_info: Dictionary = {}

## Цепи, которые сейчас в КЗ полярности (net_id -> true). При подаче напряжения такая цепь отключается защитой
var shorted_nets: Dictionary = {}
## Метки в конфликте выводов при политике TRIP (метка -> true)
var conflict_nets: Dictionary = {}

## Время последнего пересчета сети, мкс (замер для бюджета, ATTN_10 §10.5.1)
var last_recalc_usec: int = 0
## Печатать время пересчета в Output (только debug)
var log_recalc: bool = false

## ⚡Сигналы
# ⚡Сигнал о включении визуального повер-слоя на столе
signal power_layer_toggled(is_active: bool)

# ⚡Сигналы в UI
@warning_ignore("unused_signal")
signal power_tab_updated()  # вся панель обновляется
signal power_updated(contour_id: int, new_voltage: float) # Обновл. данные трака по ручке
# XX claude-switch: контур отключен защитой (КЗ на крестовине стрелки или полярности, перегрузка). Сброс: reset_output
signal contour_tripped(contour_id: int, reason: String)
## ⚡Состояние сети сброшено (новая партия): пульты обновляют ручки
signal state_reset()
## ⚡Состояние сети загружено из сейва: пульты обновляют ручки
signal state_loaded()
## ⚡Набор источников изменился (создан, удалён)
signal sources_changed()
## ⚡Шаг решателя (10 Гц): токи и состояния выводов обновлены. Индикаторы пультов читают их по этому сигналу
signal solver_stepped()
## ⚡Событие защиты вывода: kind "overload", "clear" или "trip"
signal output_event(label: int, kind: String, reason: String)
## ⚡Правила электрики сменились (пресет или тумблер): UI обновляет подписи и скрывает отключённые опции
signal rules_changed()
## ⚡Участок цепи занят или освобождён тележкой (D6): net это метка питающего вывода участка (0: участок без питания)
signal net_occupied(net: int, occupied: bool)
## ⚡Датчик занятости сменил состояние (D6)
signal sensor_triggered(sensor: C_OccupancySensor, occupied: bool)
## ⚡Событие шины аксессуаров: kind "trip" (защита), "reset"
signal bus_event(kind: String)



func _ready() -> void:
	_ensure_default_source()
	set_physics_process(true)


func _physics_process(delta: float) -> void:
	_solver_acc += delta
	if _solver_acc < SOLVER_STEP:
		return
	var dt := _solver_acc
	_solver_acc = 0.0
	_step_solver(dt)
	_step_peripherals(dt)


## Шина аксессуаров и датчики занятости (10 Гц, независимо от наличия пультов)
func _step_peripherals(dt: float) -> void:
	if bus.step(dt, mains, rules.supply_required, load_for_lights, short_protection_on()) == "trip":
		print("⚡ Шина аксессуаров отключена защитой (нагрузка выше %.1f А)" % bus.i_max)
		bus_event.emit("trip")
	_step_occupancy()


func bus_powered() -> bool:
	return bus.powered(mains, rules.supply_required)


## XX claude-wire W8: запитан ли потребитель шины. Без правила физической проводки или без клеммы шины на объекте шина питает его виртуально,
## с правилом и клеммой нужен провод, дошедший до клеммы шины (C_BusTerminal)
func bus_powered_for(e: Entity) -> bool:
	if not bus_powered():
		return false
	if not wiring_required or e == null:
		return true
	var bt := e.get_comp(C_BusTerminal) as C_BusTerminal
	return bt == null or bt.is_fed()


func reset_bus() -> void:
	bus.reset()
	bus_event.emit("reset")


## Занятость участков: тележка на рельсах (не сошедшая, не в руке) занимает связный участок трака, на котором стоит
func _step_occupancy() -> void:
	var sensors := get_tree().get_nodes_in_group(&"occupancy_sensor")
	if sensors.is_empty() and _occupied_prev.is_empty():
		return
	var occ: Dictionary = {}
	for node in get_tree().get_nodes_in_group(C_Bogie.GROUP):
		var wagon := node as Entity
		if wagon == null or wagon.is_queued_for_deletion():
			continue
		var bc := wagon.get_comp(C_Bogie) as C_Bogie
		if bc == null or bc.is_derailed:
			continue
		var ch := wagon.get_comp(C_Chassis) as C_Chassis
		if ch != null and not ch.is_on_rails:
			continue
		for b in bc.bogies_data:
			if b.current_track != null and _track_roots.has(b.current_track):
				occ[_track_roots[b.current_track]] = true
	for s in sensors:
		var sensor := s as C_OccupancySensor
		if sensor == null or sensor.entity == null or not _track_roots.has(sensor.entity):
			continue
		var is_occ := occ.has(_track_roots[sensor.entity])
		if sensor.set_occupied(is_occ):
			sensor_triggered.emit(sensor, is_occ)
	for root in occ:
		if not _occupied_prev.has(root):
			net_occupied.emit(_root_net(root), true)
	for root in _occupied_prev:
		if not occ.has(root):
			net_occupied.emit(_root_net(root), false)
	_occupied_prev = occ


## Метка питающего вывода участка (по любому траку участка), 0 если участок не питается
func _root_net(root: Variant) -> int:
	for e in _track_roots:
		if _track_roots[e] == root and is_instance_valid(e):
			var pt := (e as Entity).get_comp(C_PowerTrack) as C_PowerTrack
			if pt != null and pt.net_id != 0:
				return pt.net_id
	return 0


## Шаг решателя: токи, защита, нагрузка сети. События защиты разбираются здесь
func _step_solver(dt: float) -> void:
	if sources.is_empty():
		return
	var events := _solver.step(sources, ports, mains, dt, load_for_lights)
	for ev in events:
		var out := get_output(int(ev.label))
		if out == null:
			continue
		match String(ev.kind):
			"trip":
				_apply_output(out)
				power_updated.emit(out.label, 0.0)
				contour_tripped.emit(out.label, String(ev.reason))
				print("⚡ Перегрузка: вывод ", out.label, " отключен защитой")
			_:
				_refresh_clips()
		output_event.emit(out.label, String(ev.kind), String(ev.reason))
	_auto_reset_step()
	_refresh_clip_labels()
	solver_stepped.emit()


# --- ИСТОЧНИКИ ---

## Создать свободный источник `multi`, если источников нет (старт игры, тесты без панели, сброс)
func _ensure_default_source() -> void:
	if sources.is_empty():
		_create_source(PowerModels.MULTI)


## Метки по порядку с 1, не занятые другими источниками
func _alloc_labels(n: int) -> Array[int]:
	var res: Array[int] = []
	var l := 1
	while res.size() < n:
		if not _label_index.has(l):
			res.append(l)
		l += 1
	return res


func _create_source(model_id: StringName, forced_labels: Array = []) -> PowerSource:
	var md := PowerModels.get_model(model_id)
	var s := PowerSource.new()
	s.id = _next_source_id
	_next_source_id += 1
	s.model = model_id
	var labels: Array = forced_labels if not forced_labels.is_empty() else _alloc_labels(int(md.outputs))
	var suffix: Array = md.suffix
	for i in labels.size():
		var o := PowerOutput.new()
		o.label = int(labels[i])
		o.v_max = float(md.v_max)
		o.i_max = float(md.i_max)
		o.suffix = String(suffix[i]) if i < suffix.size() else ""
		s.outputs.append(o)
	sources.append(s)
	_rebuild_index()
	_sync_view()
	sources_changed.emit()
	return s


func _rebuild_index() -> void:
	_label_index.clear()
	for s in sources:
		for o in s.outputs:
			_label_index[o.label] = [s, o]


## Зарегистрировать источник за владельцем (панель или сущность). Свободный источник той же модели забирается
## (старт с одной панелью, смена дизайна панели: питание не пропадает и не дублируется), иначе создаётся новый
func register_source(model_id: StringName, owner_obj: Object = null) -> PowerSource:
	if not PowerModels.has_model(model_id):
		model_id = PowerModels.MULTI
	for s in sources:
		if s.model == model_id and s.is_free():
			s.owner = owner_obj
			return s
	var src := _create_source(model_id)
	src.owner = owner_obj
	return src


## Владелец отпускает источник (панель закрыта). Источник остаётся на столе со своими командами: это «виртуальный
## пульт стола игрока». Следующая панель той же модели его заберёт. Полное удаление: remove_source (3D, D4)
func unregister_source(src: PowerSource) -> void:
	if src != null:
		src.owner = null


func remove_source(src: PowerSource) -> void:
	if src == null or not sources.has(src):
		return
	sources.erase(src)
	_rebuild_index()
	_sync_view()
	_refresh_all()
	sources_changed.emit()


## Источнику сущности (3D-пульт) после загрузки возвращают номер и метки из сейва. Источник создан с новыми метками
## при сборке сущности, загрузка вернёт прежние, и PGM.load_state опознает его по id
func restore_source_identity(src: PowerSource, id: int, labels: Array) -> void:
	if src == null or not sources.has(src) or labels.size() != src.outputs.size():
		return
	src.id = id
	for i in labels.size():
		src.outputs[i].label = int(labels[i])
	_next_source_id = maxi(_next_source_id, id + 1)
	_rebuild_index()
	sources_changed.emit()


func get_output(label: int) -> PowerOutput:
	return _label_index[label][1] if _label_index.has(label) else null


func get_source_of(label: int) -> PowerSource:
	return _label_index[label][0] if _label_index.has(label) else null


## Все метки выводов по порядку
func all_labels() -> Array[int]:
	var res: Array[int] = []
	for k in _label_index.keys():
		res.append(int(k))
	res.sort()
	return res


## Подпись вывода для списков: «Вывод 3», «Вывод 11 · A»
func label_text(label: int) -> String:
	var o := get_output(label)
	if o == null:
		return "Вывод %d" % label
	return "Вывод %d" % label + (" · " + o.suffix if o.suffix != "" else "")


# --- ИНТЕРФЕЙС ДЛЯ ПУЛЬТА (UI или 3D Entity) ---

## Команда на вывод. label = -1: все выводы источника `source` (или все источники, если null), 0: никуда
func set_command(label: int, value: int, source: PowerSource = null) -> void:
	if label == 0:
		return # Нейтралка
	var outs: Array[PowerOutput] = []
	if label == -1:
		for s in sources:
			if source == null or s == source:
				outs.append_array(s.outputs)
	else:
		var o := get_output(label)
		if o != null and (source == null or get_source_of(label) == source):
			outs.append(o)
	for o in outs:
		o.command = clampi(value, -int(o.v_max), int(o.v_max))
	for o in outs:
		_apply_output(o)

	# ⚡Сигнал для UI
	power_updated.emit(label, value)

	# Подали напряжение в цепь с КЗ или конфликтом: защита отключает вывод
	if value != 0:
		for o in outs:
			_retrip_output(o)


## Совместимость: команда на вывод по метке. -1: все выводы всех источников
func set_power_pwm( _cid: int = 0, _voltage :int = 0) -> void:
	set_command(_cid, _voltage)


## Напряжение на рельсах для метки, % команды со знаком (с учётом аварийного стопа, защиты, сети)
func get_power(_cid: int) -> float:
	if not _label_index.has(_cid):
		return 0.0
	# P0: КЗ полярности обнуляет цепь без отключения вывода (D7)
	if rules.fidelity == DCSRules.Fidelity.P0 and shorted_nets.has(_cid):
		return 0.0
	return PowerSolver.voltage_of(_label_index[_cid][0], _label_index[_cid][1], mains)


## Вывод остановлен: аварийный стоп, защита, источник выключен или нет сети
func is_output_stopped(_cid: int) -> bool:
	if not _label_index.has(_cid):
		return false
	var s: PowerSource = _label_index[_cid][0]
	var o: PowerOutput = _label_index[_cid][1]
	return s.estop or not s.enabled or o.tripped or (rules.supply_required and s.needs_supply() and not mains.on) \
			or (rules.fidelity == DCSRules.Fidelity.P0 and shorted_nets.has(_cid))


## Производное представление, клипы, шейдер полос: всё, что зависит от состояния вывода
func _apply_output(o: PowerOutput) -> void:
	_sync_view()
	var v := get_power(o.label)
	for clip in active_clips:
		if is_instance_valid(clip) and clip.feed_net() == o.label:
			clip.voltage = v
			clip._change_clip_label()
	_update_shader_voltage(o.label, v)


func _sync_view() -> void:
	power_pwm.clear()
	for k in _label_index.keys():
		var o: PowerOutput = _label_index[k][1]
		power_pwm[k] = {"voltage": o.command, "is_stopped": is_output_stopped(int(k))}


## Все выводы: клипы, шейдер, представление (после загрузки, сброса, смены сети)
func _refresh_all() -> void:
	_sync_view()
	for k in _label_index.keys():
		_update_shader_voltage(int(k), get_power(int(k)))
	_refresh_clips()


func _refresh_clips() -> void:
	for clip in active_clips:
		if is_instance_valid(clip):
			clip.refresh_power()


## Метки клипов показывают ток: обновляем с шагом решателя
func _refresh_clip_labels() -> void:
	for clip in active_clips:
		if is_instance_valid(clip):
			clip._change_clip_label()


# ---Хелпер для связи с C_TrackVisual---
func _update_shader_voltage(cid: int, voltage: float) -> void:
	# Материалы контура в кэше: "<cid>_false" / "<cid>_true", у рельсов с нестандартным UV (Track Studio, ATTN_20)
	# с суффиксом "_<scale>_<swap>". Обновляем все варианты по префиксу
	var prefix_normal := str(cid) + "_false"
	var prefix_flipped := str(cid) + "_true"
	for key in C_TrackVisual.power_materials_cache.keys():
		var k := String(key)
		var mat: ShaderMaterial = C_TrackVisual.power_materials_cache[key]
		if k.begins_with(prefix_normal):
			# Передаем напряжение в шейдер
			mat.set_shader_parameter("scroll_speed", voltage * 0.01)
		elif k.begins_with(prefix_flipped):
			# Для перевернутых траков инвертируем скорость/направление
			mat.set_shader_parameter("scroll_speed", -voltage * 0.01)


# --- СТОП, ЗАЩИТА, СЕТЬ ---

## ⚡Аварийный стоп рукой: источник `source` (null: все) без напряжения, команды сохраняются. На защиту не влияет (Q8)
func emergency_stop(_stop : bool, source: PowerSource = null) -> void:
	for s in sources:
		if source != null and s != source:
			continue
		s.estop = _stop
		for o in s.outputs:
			_apply_output(o)
			power_updated.emit(o.label, get_power(o.label))
	# Сняли стоп, а КЗ в цепи осталось: защита отключает вывод снова
	if not _stop:
		_retrip_shorted()


## Включить или выключить питающую сеть (кнопка «Сеть» на панели)
func set_mains(on: bool) -> void:
	if mains.on == on:
		return
	mains.on = on
	_refresh_all()
	for l in all_labels():
		power_updated.emit(l, get_power(l))
	if on:
		_retrip_shorted()


# XX claude-switch. Отключает вывод защитой (КЗ полярности, крестовина, конфликт, перегрузка).
# Сброс: reset_output(метка) или reset_protection()
func trip_contour(_cid: int, reason: String = "") -> void:
	var o := get_output(_cid)
	if o == null or o.tripped:
		return
	PowerSolver.trip(o, reason)
	_apply_output(o)
	power_updated.emit(_cid, 0.0)
	contour_tripped.emit(_cid, reason)
	output_event.emit(_cid, "trip", reason)
	print("⚡ КЗ (", reason, "): контур ", _cid, " отключен")


## Вернуть питание вывода после отключения защитой. Если причина не устранена, защита сработает снова
func reset_output(_cid: int) -> void:
	var o := get_output(_cid)
	if o == null or not o.tripped:
		return
	PowerSolver.reset(o)
	_apply_output(o)
	power_updated.emit(_cid, get_power(_cid))
	output_event.emit(_cid, "clear", "")
	if o.command != 0:
		_retrip_output(o)


## Прежнее имя
func reset_contour(_cid: int) -> void:
	reset_output(_cid)


# --- ПРАВИЛА (D7) ---

## Применить правила: проводка, конфликт, свет, лимиты решателя, изостыки сборщика, питающая сеть. Пересчитывает сеть
func apply_rules(r: DCSRules) -> void:
	rules = r if r != null else DCSPresets.make(DCSPresets.STANDARD)
	wiring_required = rules.wiring_required
	conflict_policy = rules.conflict_policy as ConflictPolicy
	load_for_lights = rules.load_for_lights
	PowerSolver.supply_required = rules.supply_required
	_solver.fidelity_limits = rules.fidelity != DCSRules.Fidelity.P0
	_solver.protection = rules.short_protection != DCSRules.ShortProtection.NONE and _solver.fidelity_limits
	_builder.gaps_enabled = rules.gaps_enabled
	if not _solver.protection:
		for s in sources:
			for o in s.outputs:
				if o.tripped:
					PowerSolver.reset(o)
	_trip_at.clear()
	_refresh_all()
	request_recalculate()
	rules_changed.emit()
	power_tab_updated.emit()


func apply_preset(id: StringName) -> void:
	apply_rules(DCSPresets.make(id))


## Защита по КЗ полярности и конфликту включена (P1 и выше, не NONE)
func short_protection_on() -> bool:
	return rules.fidelity != DCSRules.Fidelity.P0 and rules.short_protection != DCSRules.ShortProtection.NONE


## ShortProtection.AUTO: сработавший вывод возвращается через DCSRules.AUTO_RESET_S, если КЗ и конфликта больше нет
func _auto_reset_step() -> void:
	if rules.short_protection != DCSRules.ShortProtection.AUTO:
		_trip_at.clear()
		return
	var now := Time.get_ticks_msec()
	for s in sources:
		for o in s.outputs:
			if not o.tripped:
				_trip_at.erase(o.label)
				continue
			if not _trip_at.has(o.label):
				_trip_at[o.label] = now
			elif now - int(_trip_at[o.label]) >= int(DCSRules.AUTO_RESET_S * 1000.0) \
					and not shorted_nets.has(o.label) and not conflict_nets.has(o.label):
				_trip_at.erase(o.label)
				reset_output(o.label)


## Сбросить защиту всех выводов источника `source` (null: всех источников)
func reset_protection(source: PowerSource = null) -> void:
	for s in sources:
		if source != null and s != source:
			continue
		for o in s.outputs:
			reset_output(o.label)


## Причина не устранена: КЗ полярности или конфликт выводов (политика TRIP)
func _retrip_output(o: PowerOutput) -> void:
	if o.command == 0 or o.tripped or not short_protection_on():
		return
	if shorted_nets.has(o.label):
		trip_contour(o.label, "polarity")
	elif conflict_nets.has(o.label):
		trip_contour(o.label, "conflict")


## Выводы с КЗ или конфликтом и поданной командой отключаются защитой
func _retrip_shorted() -> void:
	for cid in shorted_nets.keys():
		var o := get_output(int(cid))
		if o != null:
			_retrip_output(o)
	for cid in conflict_nets.keys():
		var o := get_output(int(cid))
		if o != null:
			_retrip_output(o)


# --- ПОРТЫ ПОТРЕБИТЕЛЕЙ ---

func register_port(port: PowerPort) -> void:
	if port != null and not ports.has(port):
		ports.append(port)


func unregister_port(port: PowerPort) -> void:
	ports.erase(port)


# --- СБРОС И СЕЙВ ---

## Сброс состояния сети: команды 0, аварийный стоп и защита сняты, сеть включена, мертвые клипы убраны.
## Зовут на новой и загруженной партии, иначе в сессии остаются старые значения (ATTN_10 P5)
func reset_state() -> void:
	for s in sources:
		s.estop = false
		s.enabled = true
		s.selected = -1
		for o in s.outputs:
			o.command = 0
			o.current = 0.0
			PowerSolver.reset(o)
	mains.on = true
	bus.load_data({})
	_occupied_prev.clear()
	shorted_nets.clear()
	conflict_nets.clear()
	net_info.clear()
	var alive: Array[C_PowerClip] = []
	for clip in active_clips:
		if is_instance_valid(clip) and is_instance_valid(clip.entity) and not clip.entity.is_queued_for_deletion():
			alive.append(clip)
	active_clips = alive
	_ensure_default_source()
	apply_rules(DCSPresets.make(DCSPresets.STANDARD))   # новая партия: «Стандарт» (D7), сейв перепишет правила в load_state
	_refresh_all()
	state_reset.emit()


## Состояние источников и сети для сейва (SavedGame.power_state)
func save_state() -> Dictionary:
	var arr: Array = []
	for s in sources:
		arr.append(s.save_data())
	return {"version": 2, "sources": arr, "mains": mains.save_data(), "next_id": _next_source_id, "rules": rules.to_dict(), "bus": bus.save_data()}


## Загрузка состояния. Пустой словарь (сейв до D2): остаются нули после reset_state.
## Источники с тем же id и моделью обновляются на месте (панель держит ссылку), остальные создаются
func load_state(d: Dictionary) -> void:
	# Правила: в сейве до D7 их нет, такой макет получает «Стандарт»
	apply_rules(DCSRules.from_dict(d.get("rules", {})) if d.has("rules") else DCSPresets.make(DCSPresets.STANDARD))
	if d.is_empty():
		return
	bus.load_data(d.get("bus", {}))
	mains.load_data(d.get("mains", {}))
	var saved: Array = d.get("sources", [])
	var kept: Array[PowerSource] = []
	for sd: Dictionary in saved:
		var model := StringName(sd.get("model", "multi"))
		if not PowerModels.has_model(model):
			model = PowerModels.MULTI
		var labels: Array = []
		for od: Dictionary in sd.get("outputs", []):
			labels.append(int(od.get("label", 0)))
		var src: PowerSource = null
		for e in sources:
			if e.id == int(sd.get("id", -1)) and e.model == model and not kept.has(e) and e.outputs.size() == labels.size():
				src = e
				break
		if src == null:
			# нет подходящего: перекладываем метки на первый свободный источник той же модели или создаём новый
			for e in sources:
				if e.model == model and not kept.has(e) and e.outputs.size() == labels.size():
					src = e
					break
		if src == null:
			# метки заняты чужими источниками: освобождаем их в индексе перед созданием
			src = _create_source(model, labels)
		else:
			for i in src.outputs.size():
				src.outputs[i].label = int(labels[i])
		src.id = int(sd.get("id", src.id))
		src.enabled = bool(sd.get("enabled", true))
		src.estop = bool(sd.get("estop", false))
		src.selected = int(sd.get("selected", -1))
		var outs: Array = sd.get("outputs", [])
		for i in src.outputs.size():
			src.outputs[i].load_data(outs[i])
		kept.append(src)
	# источники без пары в сейве: свободные удаляются, с панелью обнуляются
	for s in sources.duplicate():
		if kept.has(s):
			continue
		if s.is_free():
			sources.erase(s)
		else:
			s.estop = false
			for o in s.outputs:
				o.command = 0
				PowerSolver.reset(o)
	_next_source_id = maxi(int(d.get("next_id", 1)), _max_source_id() + 1)
	_ensure_default_source()
	_rebuild_index()
	_refresh_all()
	request_recalculate()
	sources_changed.emit()
	state_loaded.emit()


func _max_source_id() -> int:
	var m := 0
	for s in sources:
		m = maxi(m, s.id)
	return m


# --- КЛИПЫ И ЦЕПИ ---

# Создает клип на траке по кнопке инфопанели
func create_power_clip(_entity: Entity, _cid: int, _pressed: bool) -> int:

	# Проверяем: если контур равен 0 (игрок не выбрал конкретный канал) - берем первый свободный
	if _pressed and _cid == 0:
		_cid = get_free_contour_id()
		if _cid == 0:
			return 0   # свободных номеров нет

	#💡 нажата
	if  _pressed:
		# Вешаем C_PowerClip
		var power_clip = C_PowerClip.new()

		#power_clip.net_id = target_contour # set_power сделает
		_entity.add_component(power_clip)

		# Задает электрику в клип из пгм
		power_clip.set_power(_cid, get_power(_cid))

		# Вешаем на трак контур
		_entity.get_comp(C_PowerTrack).net_id = _cid

	else : # отжата
		_entity.remove_component(C_PowerClip)
		# Снимаем контур с трака
		_entity.get_comp(C_PowerTrack).net_id = 0

	return _cid


# --- ИНТЕРФЕЙС ДЛЯ ТОПОЛОГИИ (Вызывается из C_PowerClip ) ---
# Регистрация клипов в сети
func register_clip(_clip):
	if not active_clips.has(_clip):
		active_clips.append(_clip)
		request_recalculate() # запрос пересчета



func unregister_clip(_clip):
	if active_clips.has(_clip):
		active_clips.erase(_clip)
		request_recalculate() # запрос пересчета



# Возвращает список ID контуров, которые СЕЙЧАС заняты
func get_occupied_contours() -> Array[int]:
	var occupied: Array[int] = []
	for clip in active_clips:
		var n: int = clip.feed_net() if is_instance_valid(clip) else 0
		if n > 0 and not n in occupied:
			occupied.append(n)
	return occupied



## Возвращает первую метку вывода, не занятую клипами. Если все заняты, возвращает 0.
func get_free_contour_id() -> int:
	var occupied = get_occupied_contours()
	for id in all_labels():
		if not id in occupied:
			return id
	return 0



# буферный метод, который ждет, пока физика Godot уложит все рельсы на места.
func request_recalculate() -> void:
	if _recalc_pending: return # если ожидание вкл - выход
	_recalc_pending = true
	# Ждем 2 кадра физики, чтобы двойные угловые снапы и Area3D успели обновить overlap
	await get_tree().physics_frame
	await get_tree().physics_frame

	recalculate_grid()
	_recalc_pending = false
	#await get_tree().physics_frame


# Пересчет всей сети: граф цепей, лидеры и конфликты клипов, КЗ полярности. Подробно: RailNetBuilder
func recalculate_grid() -> void:
	# Освобожденные без on_removed клипы (free сущности, тесты) убираем до расчета
	active_clips = active_clips.filter(func(c): return is_instance_valid(c))
	_solve_wiring()
	var t0 := Time.get_ticks_usec()
	var res: Dictionary = _builder.solve(get_tree(), active_clips)
	last_recalc_usec = Time.get_ticks_usec() - t0
	net_info = res.nets
	_track_roots = res.roots

	# Вид обновляем только у тех, у кого цепь, полярность или авария изменились (и у новых траков)
	for e in res.changed:
		if is_instance_valid(e):
			e.send_event("on_power_view_changed", {"active": is_power_layer_active})

	# Метки клипов (конфликт, знак «−»)
	for clip in active_clips:
		if is_instance_valid(clip):
			clip._change_clip_label()

	# КЗ полярности: цепи с напряжением отключаются защитой
	shorted_nets.clear()
	for cid in res.shorts:
		shorted_nets[cid] = true
	# Политика TRIP (Q7): конфликт выводов на одной цепи отключает оба вывода, как КЗ между пультами
	conflict_nets.clear()
	if conflict_policy == ConflictPolicy.TRIP:
		for clip in active_clips:
			if is_instance_valid(clip) and clip.conflict == "label":
				conflict_nets[clip.feed_net()] = true
				conflict_nets[clip.conflict_with] = true
	_retrip_shorted()

	if log_recalc and Global.debug_mode:
		print("PGM: пересчет сети %d мкс, траков в цепях %d, клипов %d" % [last_recalc_usec, _tracks_in_nets(), active_clips.size()])

	power_tab_updated.emit()


## Физическая проводка (DeviceGraph): провода и устройства определяют метку и чётность каждого клипа
func _solve_wiring() -> void:
	get_tree().call_group(&"power_device", "sync_terminals")
	var g := DeviceGraph.new()
	for w in get_tree().get_nodes_in_group(&"power_wire"):
		var cw := w as C_Wire
		if cw != null and cw.is_valid_wire():
			g.add_wire(cw.a, cw.b, cw.twist)
	for clip in active_clips:
		if not is_instance_valid(clip) or clip.terminal == null or not is_instance_valid(clip.terminal):
			continue
		clip.apply_drive(g.drive(clip.terminal))
	# XX claude-wire W8: потребители шины аксессуаров (дом с лампами): дошёл ли провод до клеммы шины
	for n in get_tree().get_nodes_in_group(&"bus_terminal"):
		var bt := n as C_BusTerminal
		if bt != null and is_instance_valid(bt.terminal):
			bt.apply_bus(g.reach(bt.terminal, PowerTerminal.Kind.ACCESSORY))


func _tracks_in_nets() -> int:
	var n := 0
	for k in net_info:
		n += int(net_info[k].tracks)
	return n



# Срабатывает при переключении слоя электрики в топ панели
func toggle_power_layer(state: bool):
	is_power_layer_active = state
	power_layer_toggled.emit(state)
	# Получаем список всех сущностей с C_PowerTrack
	var all_tracks = get_tree().get_nodes_in_group("power_track")
	for track_entity in all_tracks:
		track_entity.send_event("on_power_view_changed", {"active": state})
