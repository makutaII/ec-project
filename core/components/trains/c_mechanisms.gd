class_name C_Mechanisms extends ICapability

####################
## Способность. Подвижные части вагона/локо: двери, позже пантограф, дышла, фары...
####################
## Один компонент держит СПИСОК механизмов (Entity не допускает два компонента одного типа).
## Конфиг: WagonConfig.mechanisms (Array[MechanismConfig]). Узлы ищет PartRegistry (C_Visual.parts),
## по роли, а не по имени.
##
## ИСКЛЮЧЕНИЕ из Node Ownership: меши принадлежит C_TrainVisual, но трансформ узла, который
## объявлен механизмом (part_role), двигает ТОЛЬКО этот компонент. C_TrainVisual их не трогает.
##
## События IN:  on_mechanism_set {id, state 0..1}, on_mechanism_toggle {id}
## События OUT: on_mechanism_changed {id, state, moving} - начало и конец движения (звук, UI)
##
## СВЕТ (ATTN_16_mechanisms.md). Тот же компонент держит и источники света: WagonConfig.lights (Array[LightConfig]).
## Источники создаются КОДОМ в точках из конфига (позиция, поворот, родитель-роль), маркеры в сцене не нужны.
## События IN:  on_light_set {id, state 0..1}, on_light_toggle {id}, on_light_gain {id, gain 0..2}, on_light_auto {id}
## События OUT: on_light_changed {id, state, changing}
## Правила (LightConfig.rule): NIGHT (GFX.time_of_day_changed), DIRECTION (знак скорости и ось движения C_Chassis),
## ALWAYS. Команда игрока ставит manual и перекрывает правило до события-сброса или команды on_light_auto.
## Бюджет: источники регистрируются в GFX.light_budget, он скрывает лишние (Lamp.culled), ближайшие к камере остаются.
## Тени у источников сущностей выключены всегда (тени только у лампы стола, GFX).
## Отладка (Global.debug_mode, сущность выбрана): I - вкл/выкл весь свет, Shift+I - метки источников и размеры кузова в Output
## Порядок в components: Identity -> TrainVisual -> ... -> Mechanisms

class Mech extends RefCounted:
	var cfg: MechanismConfig
	var node: Node3D            # null - часть не найдена
	var rest: Transform3D       # поза покоя (t = 0), как пришла из сцены
	var t := 0.0                # текущее состояние 0..1
	var target := 0.0
	var enabled := true
	var manual := false         # игрок взял управление (на будущее: AUTO-правила)
	var anim: Animation         # только ANIM: анимация модели (плеер модели не запускается, позы ставит сам механизм)
	var anim_tracks: Array = [] # только ANIM: [{node: Node3D, idx: int, kind: Animation.TrackType}]
	var anim_t0 := 0.0          # только ANIM: время первого ключа = состояние 0
	var anim_t1 := 0.0          # только ANIM: время последнего ключа = состояние 1
	var dbg_dirty := false      # отладка: поза узлов расходится с состоянием (уже сообщено)
	var linear := false         # только ANIM: t ведёт внешний источник (фаза колеса), время анимации линейно по t, без smoothstep

	## Часть найдена: узел (SLIDE, ROTATE) или дорожки анимации (ANIM)
	func found() -> bool:
		if cfg.actuator == MechanismConfig.Actuator.ANIM:
			return anim != null and not anim_tracks.is_empty()
		return node != null

	func is_moving() -> bool:
		return not is_equal_approx(t, target)

	## Возвращает true, если дошли до цели в этом шаге
	func step(dt: float) -> bool:
		var was_moving := is_moving()
		t = move_toward(t, target, dt / maxf(cfg.duration, 0.01))
		apply()
		return was_moving and not is_moving()

	func apply() -> void:
		var k := t if linear else smoothstep(0.0, 1.0, t)
		if cfg.actuator == MechanismConfig.Actuator.ANIM:
			# Состояние 0..1 это время между первым и последним ключом анимации (у экспорта из Blender первый ключ
			# не обязан стоять в нуле). Позы ставим сами, без AnimationPlayer: нет автопроигрывания, нет конфликта плееров
			if anim != null:
				var time := lerpf(anim_t0, anim_t1, k)
				for e in anim_tracks:
					var n: Node3D = e.node
					if not is_instance_valid(n):
						continue
					match e.kind:
						Animation.TYPE_POSITION_3D:
							n.position = anim.position_track_interpolate(e.idx, time)
						Animation.TYPE_ROTATION_3D:
							n.quaternion = anim.rotation_track_interpolate(e.idx, time)
						Animation.TYPE_SCALE_3D:
							n.scale = anim.scale_track_interpolate(e.idx, time)
			return
		if node == null or not is_instance_valid(node):
			return
		var ax := cfg.axis.normalized() if cfg.axis.length_squared() > 0.0001 else Vector3.RIGHT
		match cfg.actuator:
			MechanismConfig.Actuator.SLIDE:
				node.transform = Transform3D(rest.basis, rest.origin + ax * cfg.travel * k)
			MechanismConfig.Actuator.ROTATE:
				node.transform = Transform3D(rest.basis * Basis(ax, deg_to_rad(cfg.travel * k)), rest.origin)

	## Только ANIM: расхождение между фактической позой узлов и позой по текущему состоянию (0 - совпадает; поворот в радианах)
	func pose_error() -> float:
		if anim == null:
			return 0.0
		var time := lerpf(anim_t0, anim_t1, t if linear else smoothstep(0.0, 1.0, t))
		var err := 0.0
		for e in anim_tracks:
			var n: Node3D = e.node
			if not is_instance_valid(n):
				continue
			match e.kind:
				Animation.TYPE_POSITION_3D:
					err = maxf(err, n.position.distance_to(anim.position_track_interpolate(e.idx, time)))
				Animation.TYPE_ROTATION_3D:
					err = maxf(err, n.quaternion.angle_to(anim.rotation_track_interpolate(e.idx, time)))
				Animation.TYPE_SCALE_3D:
					err = maxf(err, n.scale.distance_to(anim.scale_track_interpolate(e.idx, time)))
		return err


class Lamp extends RefCounted:
	var cfg: LightConfig
	var anchor: Node3D          # родитель источника; null - узел-родитель не найден
	var light: Light3D          # null - Light3D не создан (kind EMISSIVE)
	var glow: Node3D            # светящиеся элементы (LightConfig.glow_*), null - нет
	var glow_mat: StandardMaterial3D
	var gizmo: Node3D           # отладочная метка точки и направления
	var t := 0.0                # текущая яркость 0..1
	var target := 0.0
	var enabled := true
	var manual := false         # игрок перекрыл правило (NIGHT, DIRECTION) до события-сброса
	var gain := 1.0             # множитель яркости 0..LightConfig.GAIN_MAX (слайдер в InfoPanel)
	var ghost := false          # сущность - призрак, источник скрыт
	var culled := false         # скрыт бюджетом (LightBudget)
	var delay := 0.0            # оставшаяся случайная задержка перед переходом (LightConfig.delay_jitter)
	var uses_track := false     # питается с рельсов: светит только при напряжении под сущностью
	var uses_bus := false       # питается от шины аксессуаров (D6): светит, пока шина запитана

	func uses_power() -> bool:
		return uses_track or uses_bus
	var power := 1.0            # доля питания 0..1, плавно догоняет power_target
	var power_target := 1.0

	const POWER_FADE := 0.3     # секунд на полное изменение доли питания

	func is_changing() -> bool:
		return not is_equal_approx(t, target) or not is_equal_approx(power, power_target)

	## Итоговая яркость 0..1: состояние на долю питания
	func level() -> float:
		return t * power

	## Light3D хочет гореть (до учёта бюджета)
	func wants_on() -> bool:
		return light != null and level() > 0.001 and not ghost

	func has_output() -> bool:
		return light != null or glow != null

	## Возвращает true, если дошли до цели в этом шаге
	func step(dt: float) -> bool:
		var was := is_changing()
		power = move_toward(power, power_target, dt / POWER_FADE)
		if delay > 0.0:
			delay -= dt
			apply()
			return false
		t = move_toward(t, target, dt / maxf(cfg.fade_time, 0.01))
		apply()
		return was and not is_changing()

	func apply() -> void:
		if light != null and is_instance_valid(light):
			light.light_energy = cfg.energy * gain * level()
			light.visible = wants_on() and not culled
		if glow != null and is_instance_valid(glow):
			var on := level() > 0.001 and not ghost
			glow.visible = on
			if on and glow_mat:
				glow_mat.emission_energy_multiplier = cfg.glow_energy * gain * level()


var _mechs: Dictionary = {}          # StringName -> Mech
var _order: Array[StringName] = []
var _saved: Dictionary = {}          # id(String) -> {t, manual, enabled}
var _lamps: Dictionary = {}          # StringName -> Lamp
var _lamp_order: Array[StringName] = []
var _saved_lights: Dictionary = {}   # id(String) -> {t, manual, enabled}
var _gizmos_on := false
var _ghost := false
var _debug := false                   # у какого-то механизма включён MechanismConfig.debug_log
var _lights_built := false     # on_entity_ready создал источники (set_light_configs пересоздаёт их)
var _phase_mechs: Array[Mech] = []   # механизмы с source = WHEEL_PHASE: позы ставит _update_phase в physics_process
var _bogie_ref: C_Bogie
## Направление движения для DIRECTION: 1 носом (-Z) вперёд, -1 хвостом
var _dir := 1
var _has_dir := false       # есть источники с правилом DIRECTION
var _has_power := false     # есть источники, питающиеся с рельсов

const DIR_SPEED_EPS := 0.05

## Конфиги из паспорта (WagonConfig.mechanisms и WagonConfig.lights). Задает MechanismsSetting до add_component
var mechanism_configs: Array[MechanismConfig] = []
var light_configs: Array[LightConfig] = []


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func on_entity_ready() -> void:
	var vis := get_comp(C_Visual) as C_Visual
	if vis == null or vis.parts == null:
		return
	_ghost = has_comp(C_Ghost)
	for c in mechanism_configs:
		var cfg := c as MechanismConfig
		if cfg == null or _mechs.has(cfg.id):
			continue
		var m := Mech.new()
		m.cfg = cfg
		m.enabled = cfg.enabled
		if cfg.actuator == MechanismConfig.Actuator.ANIM:
			_setup_anim(m, vis)
		else:
			m.node = vis.parts.find_one(cfg.part_role, cfg.part_aliases, &"Node3D", null, str(entity.name)) as Node3D
			if m.node:
				m.rest = m.node.transform
		m.t = cfg.start_state
		m.target = cfg.start_state
		if cfg.source == MechanismConfig.Source.WHEEL_PHASE:
			if cfg.actuator == MechanismConfig.Actuator.ANIM:
				m.linear = true
				_phase_mechs.append(m)
			else:
				push_warning("[C_Mechanisms] %s: механизм '%s': источник WHEEL_PHASE работает только с actuator = ANIM" % [entity.name, cfg.id])
		_mechs[cfg.id] = m
		_order.append(cfg.id)
		_debug = _debug or cfg.debug_log
	for msg in find_node_conflicts(_order.map(func(i): return _mechs[i])):
		push_warning("[C_Mechanisms] %s: %s" % [entity.name, msg])
	_apply_saved()
	for id in _order:
		_mechs[id].apply()

	_create_lamps(vis)
	_lights_built = true


## Источники света по light_configs: узлы, правила, шина, бюджет
func _create_lamps(vis: C_Visual) -> void:
	for c in light_configs:
		var lc := c as LightConfig
		if lc == null or _lamps.has(lc.id):
			continue
		_lamps[lc.id] = _build_lamp(lc, vis)
		_lamp_order.append(lc.id)
	_apply_saved_lights()
	_apply_all_lamps()
	_setup_rules()
	_register_bus()
	if not _lamps.is_empty() and GFX.light_budget:
		GFX.light_budget.register(self)


## Заменить набор источников света (XX claude-library L7: здание из генератора меняет окна вместе с формой).
## До on_entity_ready только запоминает конфиги; после пересоздаёт источники. Сохранённые состояния
## (_saved_lights) остаются и применяются к источникам с теми же id
func set_light_configs(configs: Array[LightConfig]) -> void:
	light_configs = configs
	if not _lights_built:
		return
	_clear_lamps()
	var vis := get_comp(C_Visual) as C_Visual
	if vis != null and vis.parts != null:
		_create_lamps(vis)


func _clear_lamps() -> void:
	for id in _lamp_order:
		var l: Lamp = _lamps[id]
		for n in [l.light, l.glow, l.gizmo]:
			if n != null and is_instance_valid(n):
				(n as Node).queue_free()
	_lamps.clear()
	_lamp_order.clear()
	if is_instance_valid(PGM):
		PGM.bus.remove_consumer(self)
	if is_instance_valid(GFX) and GFX.light_budget:
		GFX.light_budget.unregister(self)


## true, если значения ключей дорожки позиции, поворота или масштаба различаются (дорожка что-то двигает)
static func track_moves(anim: Animation, i: int) -> bool:
	var keys := anim.track_get_key_count(i)
	if keys < 2:
		return false
	match anim.track_get_type(i):
		Animation.TYPE_POSITION_3D, Animation.TYPE_SCALE_3D:
			var v0: Vector3 = anim.track_get_key_value(i, 0)
			for j in range(1, keys):
				if not v0.is_equal_approx(anim.track_get_key_value(i, j) as Vector3):
					return true
		Animation.TYPE_ROTATION_3D:
			var q0: Quaternion = anim.track_get_key_value(i, 0)
			for j in range(1, keys):
				if q0.angle_to(anim.track_get_key_value(i, j) as Quaternion) > 0.0001:
					return true
	return false


## Сообщения об узлах, которые ведут сразу несколько механизмов (они перезаписывали бы позы друг друга). mechs: массив Mech
static func find_node_conflicts(mechs: Array) -> Array[String]:
	var owners := {}  # instance_id -> {name, ids}
	for m in mechs:
		var nodes: Array = []
		if m.cfg.actuator == MechanismConfig.Actuator.ANIM:
			for e in m.anim_tracks:
				if not nodes.has(e.node):
					nodes.append(e.node)
		elif m.node != null:
			nodes.append(m.node)
		for n in nodes:
			var key: int = (n as Node).get_instance_id()
			if not owners.has(key):
				owners[key] = {"name": (n as Node).name, "ids": []}
			(owners[key].ids as Array).append(str(m.cfg.id))
	var res: Array[String] = []
	for key in owners:
		var o: Dictionary = owners[key]
		if (o.ids as Array).size() > 1:
			res.append("узел '%s' ведут сразу механизмы %s: они перезаписывают позы друг друга" % [o.name, ", ".join(PackedStringArray(o.ids))])
	return res


## ANIM: находит в модели AnimationPlayer с нужной анимацией, берёт её Animation и дорожки позиции, поворота и масштаба узлов.
## Плеер модели не трогаем и свои плееры не заводим: позы по состоянию ставит Mech.apply (одна анимация на механизм,
## в ней может быть сколько угодно узлов). Дорожки костей и неизвестные узлы пропускаются с предупреждением
func _setup_anim(m: Mech, vis: C_Visual) -> void:
	bind_anim(m, vis.instance, str(entity.name) if entity else "?")


## Общее ядро ANIM для вагонов и комнат (RoomMechanism, ATTN_25 RM5): привязывает механизм m к анимации mech_<id> (или anim_name)
## плеера внутри root (сам root тоже может быть AnimationPlayer). true: дорожки найдены. owner_name только для сообщений
static func bind_anim(m: Mech, root: Node, owner_name: String) -> bool:
	var aname: StringName = m.cfg.anim_name if m.cfg.anim_name != &"" else StringName("mech_%s" % m.cfg.id)
	var players: Array[Node] = root.find_children("*", "AnimationPlayer", true, false)
	if root is AnimationPlayer:
		players.push_front(root)
	var src: AnimationPlayer = null
	for n in players:
		if (n as AnimationPlayer).has_animation(aname):
			src = n
			break
	if src == null:
		push_warning("[C_Mechanisms] %s: анимация '%s' не найдена в модели (экспорт из Blender: режим Actions, имя mech_<id>)" % [owner_name, aname])
		return false
	var base := src.get_node_or_null(src.root_node)
	if base == null:
		push_warning("[C_Mechanisms] %s: у плеера анимации '%s' не найден корень (root_node)" % [owner_name, aname])
		return false
	var anim: Animation = src.get_animation(aname)
	var tracks: Array = []
	var t0 := INF
	var t1 := -INF
	for i in anim.get_track_count():
		var kind := anim.track_get_type(i)
		if kind != Animation.TYPE_POSITION_3D and kind != Animation.TYPE_ROTATION_3D and kind != Animation.TYPE_SCALE_3D:
			continue
		var keys := anim.track_get_key_count(i)
		if not anim.track_is_enabled(i) or keys == 0:
			continue
		var path := anim.track_get_path(i)
		if path.get_subname_count() > 0:
			continue # кость скелета
		if not track_moves(anim, i):
			# постоянная дорожка (ключи покоя без движения) ничего не двигает, а запись её значения перебила бы чужой механизм
			if m.cfg.debug_log:
				print("[Mech %s] дорожка %d (%s) постоянная, пропущена" % [m.cfg.id, i, path])
			continue
		var node := base.get_node_or_null(NodePath(path.get_concatenated_names())) as Node3D
		if node == null:
			push_warning("[C_Mechanisms] %s: анимация '%s': узел '%s' не найден" % [owner_name, aname, path])
			continue
		tracks.append({"node": node, "idx": i, "kind": kind})
		if m.cfg.debug_log:
			var kn := "позиция" if kind == Animation.TYPE_POSITION_3D else ("поворот" if kind == Animation.TYPE_ROTATION_3D else "масштаб")
			print("[Mech %s] дорожка %d: %s -> узел %s (%s), ключей %d, %.3f..%.3f с" % [m.cfg.id, i, path, base.get_path_to(node), kn,
					keys, anim.track_get_key_time(i, 0), anim.track_get_key_time(i, keys - 1)])
		t0 = minf(t0, anim.track_get_key_time(i, 0))
		t1 = maxf(t1, anim.track_get_key_time(i, keys - 1))
	if tracks.is_empty():
		push_warning("[C_Mechanisms] %s: в анимации '%s' нет дорожек позиции, поворота или масштаба узлов" % [owner_name, aname])
		return false
	m.anim = anim
	m.anim_tracks = tracks
	m.anim_t0 = t0
	m.anim_t1 = maxf(t1, t0)
	return true


## Лампы на шине аксессуаров нагружают её (D6): потребитель регистрируется в PGM.bus
func _register_bus() -> void:
	if _ghost:
		return
	for id in _lamp_order:
		if (_lamps[id] as Lamp).uses_bus:
			PGM.bus.add_consumer(self)
			return


## Мощность ламп на шине, Вт (AccessoryBus.step вызывает при load_for_lights)
func bus_watts() -> float:
	var w := 0.0
	for id in _lamp_order:
		var l: Lamp = _lamps[id]
		if l.uses_bus and l.anchor != null:
			w += l.cfg.power_w * l.level()
	return w


func _exit_tree() -> void:
	if is_instance_valid(PGM):
		PGM.bus.remove_consumer(self)
	if not is_instance_valid(GFX):
		return
	if GFX.light_budget:
		GFX.light_budget.unregister(self)
	if GFX.time_of_day_changed.is_connected(_on_time_of_day_changed):
		GFX.time_of_day_changed.disconnect(_on_time_of_day_changed)


func on_component_added(type: Script) -> void:
	if type == C_Ghost:
		_ghost = true
		_apply_all_lamps()


func on_component_removed(type: Script) -> void:
	if type == C_Ghost:
		_ghost = false
		_apply_all_lamps()


# ==========================================
# Команды (шина)
# ==========================================

func on_mechanism_set(data: Dictionary) -> void:
	set_state(data.get("id", &""), data.get("state", 1.0))


func on_mechanism_toggle(data: Dictionary) -> void:
	var m: Mech = _mechs.get(StringName(data.get("id", &"")))
	if m:
		set_state(m.cfg.id, 0.0 if m.target > 0.5 else 1.0)


## Публичный API (для InfoPanel и тестов)
func set_state(id: StringName, state: float) -> void:
	var m: Mech = _mechs.get(StringName(id))
	if m == null or not m.enabled or _ghost or m.cfg.source != MechanismConfig.Source.COMMAND:
		return   # механизмом с внешним источником (фаза колеса) команды не управляют
	m.target = clampf(state, 0.0, 1.0)
	m.manual = true
	_dbg(m, "команда: цель %.2f (сейчас t=%.2f)" % [m.target, m.t])
	set_process(true)
	entity.send_event("on_mechanism_changed", {"id": m.cfg.id, "state": m.target, "moving": true})


func set_enabled(id: StringName, on: bool) -> void:
	var m: Mech = _mechs.get(StringName(id))
	if m:
		m.enabled = on


func _dbg(m: Mech, msg: String) -> void:
	if m.cfg.debug_log:
		print("[Mech %s] %s" % [m.cfg.id, msg])


## Отладка (MechanismConfig.debug_log): сообщает, если поза неподвижного ANIM-механизма расходится с его состоянием,
## и кто в этот момент двигался. Работает, пока хоть что-то движется (_process иначе выключен)
func _watch_poses() -> void:
	var moving := PackedStringArray()
	for id in _order:
		if (_mechs[id] as Mech).is_moving():
			moving.append(str(id))
	for id in _order:
		var m: Mech = _mechs[id]
		if m.cfg.actuator != MechanismConfig.Actuator.ANIM or not m.cfg.debug_log or m.is_moving():
			continue
		var err := m.pose_error()
		if err > 0.01 and not m.dbg_dirty:
			m.dbg_dirty = true
			print("[Mech %s] ПОЗА ИЗМЕНЕНА СНАРУЖИ: ошибка %.3f при t=%.2f, сейчас двигаются: %s" % [id, err, m.t, ", ".join(moving) if not moving.is_empty() else "никто"])
		elif err <= 0.01 and m.dbg_dirty:
			m.dbg_dirty = false
			print("[Mech %s] поза восстановлена" % id)


## Список для вкладки "Механизмы" в InfoPanel
func get_list() -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	for id in _order:
		var m: Mech = _mechs[id]
		res.append({
			"id": id, "title": m.cfg.title, "t": m.t, "target": m.target,
			"found": m.found(), "enabled": m.enabled, "moving": m.is_moving(),
		})
	return res


func _process(delta: float) -> void:
	var any := false
	for id in _order:
		var m: Mech = _mechs[id]
		if not m.is_moving():
			continue
		if m.step(delta):
			_dbg(m, "дошёл до t=%.2f" % m.t)
			entity.send_event("on_mechanism_changed", {"id": id, "state": m.t, "moving": false})
		any = any or m.is_moving()
	if _debug:
		_watch_poses()
	for id in _lamp_order:
		var l: Lamp = _lamps[id]
		if not l.is_changing():
			continue
		if l.step(delta):
			entity.send_event("on_light_changed", {"id": id, "state": l.t, "changing": false})
		any = any or l.is_changing()
	if not any:
		set_process(false)


# ==========================================
# СВЕТ: команды (шина) и API
# ==========================================

func on_light_set(data: Dictionary) -> void:
	set_light(data.get("id", &""), data.get("state", 1.0))


func on_light_toggle(data: Dictionary) -> void:
	var l: Lamp = _lamps.get(StringName(data.get("id", &"")))
	if l:
		set_light(l.cfg.id, 0.0 if l.target > 0.5 else 1.0)


## Публичный API (для InfoPanel и тестов). state 0..1: яркость
func set_light(id: StringName, state: float) -> void:
	var l: Lamp = _lamps.get(StringName(id))
	if l == null or not l.enabled or _ghost or l.anchor == null:
		return
	l.target = clampf(state, 0.0, 1.0)
	l.manual = true
	l.delay = 0.0
	set_process(true)
	entity.send_event("on_light_changed", {"id": l.cfg.id, "state": l.target, "changing": l.is_changing()})


func set_light_enabled(id: StringName, on: bool) -> void:
	var l: Lamp = _lamps.get(StringName(id))
	if l:
		l.enabled = on


func on_light_gain(data: Dictionary) -> void:
	set_light_gain(data.get("id", &""), data.get("gain", 1.0))


func on_light_auto(data: Dictionary) -> void:
	set_light_auto(data.get("id", &""))


## Множитель яркости 0..LightConfig.GAIN_MAX (к energy из конфига)
func set_light_gain(id: StringName, gain: float) -> void:
	var l: Lamp = _lamps.get(StringName(id))
	if l == null or not l.enabled or _ghost:
		return
	l.gain = clampf(gain, 0.0, LightConfig.GAIN_MAX)
	l.apply()


## Вернуть источник правилу (снять manual)
func set_light_auto(id: StringName) -> void:
	var l: Lamp = _lamps.get(StringName(id))
	if l == null or _ghost:
		return
	l.manual = false
	_drive_lamp(l, false)


# ==========================================
# СВЕТ: правила (LightConfig.rule)
# ==========================================

func _setup_rules() -> void:
	var has_night := false
	_has_dir = false
	_has_power = false
	for id in _lamp_order:
		var l: Lamp = _lamps[id]
		match l.cfg.rule:
			LightConfig.Rule.DIRECTION:
				_has_dir = true
			LightConfig.Rule.NIGHT:
				has_night = true
		if l.uses_power():
			_has_power = true
	if has_night and not GFX.time_of_day_changed.is_connected(_on_time_of_day_changed):
		GFX.time_of_day_changed.connect(_on_time_of_day_changed)
	set_physics_process(_has_dir or _has_power or not _phase_mechs.is_empty())
	_drive_all(true)


## Значение, которое выставляет правило: 0 или 1, либо -1 если правило не управляет источником
func _rule_value(l: Lamp) -> float:
	match l.cfg.rule:
		LightConfig.Rule.NIGHT:
			return 1.0 if l.cfg.night_times.has(String(GFX.state.time)) else 0.0
		LightConfig.Rule.DIRECTION:
			return 1.0 if (l.cfg.dir_end == LightConfig.End.FRONT) == (_dir > 0) else 0.0
		LightConfig.Rule.ALWAYS:
			return 1.0
		LightConfig.Rule.POWERED:
			# горит, пока есть питание: доля питания учтена в Lamp.level()
			return 1.0 if l.uses_power() else 0.0
	return -1.0


## manual, отключённый или не найденный источник правило не трогает
func _drive_lamp(l: Lamp, instant: bool) -> void:
	if l.manual or not l.enabled or l.anchor == null:
		return
	var v := _rule_value(l)
	if v < 0.0:
		return
	l.target = v
	if instant:
		l.t = v
		l.apply()
	elif l.is_changing():
		l.delay = randf() * l.cfg.delay_jitter if l.cfg.delay_jitter > 0.0 else 0.0
		set_process(true)
		entity.send_event("on_light_changed", {"id": l.cfg.id, "state": l.target, "changing": true})


func _drive_all(instant: bool) -> void:
	for id in _lamp_order:
		_drive_lamp(_lamps[id], instant)


func _on_time_of_day_changed(_id: StringName) -> void:
	for id in _lamp_order:
		var l: Lamp = _lamps[id]
		if l.cfg.rule == LightConfig.Rule.NIGHT:
			l.manual = false
			_drive_lamp(l, false)


## Направление: знак скорости относительно оси движения (get_motion_axis учитывает разворот контура).
## Стоим или сошли с рельсов: остаётся последнее направление
func _physics_process(_delta: float) -> void:
	if _ghost:
		return
	_update_phase()
	_update_power()
	_update_direction()


## Привод от колеса (source = WHEEL_PHASE): состояние механизма это фаза колеса за оборот, позы линейно по анимации.
## Колёса стоят: фаза не меняется, ничего не пересчитывается
func _update_phase() -> void:
	if _phase_mechs.is_empty():
		return
	if _bogie_ref == null:
		_bogie_ref = get_comp(C_Bogie) as C_Bogie
		if _bogie_ref == null:
			return
	for m in _phase_mechs:
		if not m.enabled or not m.found():
			continue
		var ph := _bogie_ref.wheel_phase(m.cfg.part_role)
		if m.cfg.phase_reverse:
			ph = BogieMath.reverse_phase(ph)
		if absf(ph - m.t) < 0.0002:
			continue
		m.t = ph
		m.target = ph
		m.apply()


# ==========================================
# СВЕТ: питание с рельсов (LightConfig.power_source)
# ==========================================

func _uses_track(cfg: LightConfig) -> bool:
	match cfg.power_source:
		LightConfig.LightSupply.TRACK:
			return true
		LightConfig.LightSupply.AUTO:
			return has_comp(C_Bogie)
	return false


## Напряжение под сущностью: ведущее питание тележек (C_Bogie.best_supply, то же, что у мотора).
## Не на рельсах или контур без питания: 0
func _track_voltage() -> float:
	var chassis := get_comp(C_Chassis) as C_Chassis
	var bogie_comp := get_comp(C_Bogie) as C_Bogie
	if chassis == null or bogie_comp == null or not chassis.is_on_rails:
		return 0.0
	return float(bogie_comp.best_supply().voltage)


func _update_power() -> void:
	if not _has_power:
		return
	var v := absf(_track_voltage())
	var bus_on := PGM.bus_powered()
	for id in _lamp_order:
		var l: Lamp = _lamps[id]
		if not l.uses_power():
			continue
		var full := maxf(l.cfg.power_full_voltage, l.cfg.power_min_voltage + 0.01)
		var f := clampf(inverse_lerp(l.cfg.power_min_voltage, full, v), 0.0, 1.0)
		if l.uses_bus:
			f = 1.0 if bus_on else 0.0
		if not is_equal_approx(f, l.power_target):
			l.power_target = f
			set_process(true)


func _update_direction() -> void:
	if not _has_dir:
		return
	var ch := get_comp(C_Chassis) as C_Chassis
	if ch == null or not ch.is_on_rails or absf(ch.current_speed) < DIR_SPEED_EPS:
		return
	var s := signf((-entity.global_basis.z).dot(ch.get_motion_axis())) * signf(ch.current_speed)
	if s == 0.0:
		return
	var d := 1 if s > 0.0 else -1
	if d == _dir:
		return
	_dir = d
	for id in _lamp_order:
		var l: Lamp = _lamps[id]
		if l.cfg.rule == LightConfig.Rule.DIRECTION:
			l.manual = false
			_drive_lamp(l, false)


## Список для вкладки "Механизмы" в InfoPanel (раздел "Свет")
func get_light_list() -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	for id in _lamp_order:
		var l: Lamp = _lamps[id]
		res.append({
			"id": id, "title": l.cfg.title, "t": l.t, "target": l.target,
			"found": l.anchor != null and l.has_output(), "enabled": l.enabled, "changing": l.is_changing(),
			"gain": l.gain, "rule": l.cfg.rule, "manual": l.manual, "culled": l.culled and l.wants_on(),
			"no_power": l.uses_power() and l.power_target < 0.001,
		})
	return res


func _build_lamp(cfg: LightConfig, vis: C_Visual) -> Lamp:
	var l := Lamp.new()
	l.cfg = cfg
	l.enabled = cfg.enabled
	l.gain = clampf(cfg.brightness, 0.0, LightConfig.GAIN_MAX)
	l.ghost = _ghost
	l.uses_track = _uses_track(cfg)
	l.uses_bus = cfg.power_source == LightConfig.LightSupply.BUS
	if l.uses_power():
		l.power = 0.0          # до первого замера напряжения лампа не светит
		l.power_target = 0.0
	var parent: Node3D = vis.instance
	if cfg.anchor_role != &"":
		parent = vis.parts.find_one(cfg.anchor_role, cfg.anchor_aliases, &"Node3D", null, str(entity.name)) as Node3D
	l.anchor = parent
	if parent == null:
		return l

	match cfg.kind:
		LightConfig.Kind.SPOT:
			var s := SpotLight3D.new()
			s.spot_range = cfg.light_range
			s.spot_angle = cfg.spot_angle
			s.spot_attenuation = cfg.spot_attenuation
			l.light = s
		LightConfig.Kind.OMNI:
			var o := OmniLight3D.new()
			o.omni_range = cfg.light_range
			l.light = o
		_:
			pass   # EMISSIVE: только светящиеся элементы (_build_glow)

	if l.light:
		l.light.name = "Light_" + String(cfg.id)
		l.light.light_color = cfg.color
		l.light.light_energy = 0.0
		l.light.shadow_enabled = false     # тени только у лампы стола
		l.light.visible = false
		l.light.position = cfg.position
		l.light.rotation_degrees = cfg.rotation_deg
		parent.add_child(l.light)

	_build_glow(l, parent)

	l.gizmo = _make_gizmo(cfg)
	l.gizmo.position = cfg.position
	l.gizmo.rotation_degrees = cfg.rotation_deg
	l.gizmo.visible = _gizmos_on
	parent.add_child(l.gizmo)

	l.t = cfg.start_state
	l.target = cfg.start_state
	return l


## Светящиеся элементы: диск или шарик в точке источника и прямоугольники (окна)
func _build_glow(l: Lamp, parent: Node3D) -> void:
	var cfg := l.cfg
	var rects: Array[GlowRect] = []
	for i in cfg.glow_rects.size():
		var gr: GlowRect = cfg.glow_rects[i]
		if gr == null:
			continue
		if cfg.glow_rect_ratio < 1.0:
			var h := absi(hash("%s/%s/%d" % [entity.name, cfg.id, i])) % 1000
			if float(h) / 1000.0 >= cfg.glow_rect_ratio:
				continue
		rects.append(gr)
	var has_point := cfg.glow_shape != LightConfig.GlowShape.NONE
	if not has_point and rects.is_empty():
		return

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.BLACK
	mat.emission_enabled = true
	mat.emission = cfg.color
	mat.emission_energy_multiplier = 0.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var holder := Node3D.new()
	holder.name = "Glow_" + String(cfg.id)
	holder.visible = false

	if has_point:
		var pt := Node3D.new()
		pt.position = cfg.position + cfg.glow_offset
		pt.rotation_degrees = cfg.rotation_deg
		var mi := MeshInstance3D.new()
		if cfg.glow_shape == LightConfig.GlowShape.SPHERE:
			var sm := SphereMesh.new()
			sm.radius = cfg.glow_size * 0.5
			sm.height = cfg.glow_size
			mi.mesh = sm
		else:
			var cm := CylinderMesh.new()
			cm.top_radius = cfg.glow_size * 0.5
			cm.bottom_radius = cfg.glow_size * 0.5
			cm.height = cfg.glow_size * 0.15
			mi.mesh = cm
			mi.rotation_degrees = Vector3(90.0, 0.0, 0.0)   # ось цилиндра вдоль оси источника
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		pt.add_child(mi)
		holder.add_child(pt)

	for gr in rects:
		var q := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = gr.size
		q.mesh = qm
		q.material_override = mat
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		q.position = gr.position
		q.rotation_degrees = gr.rotation_deg
		holder.add_child(q)

	parent.add_child(holder)
	l.glow = holder
	l.glow_mat = mat


func _apply_all_lamps() -> void:
	for id in _lamp_order:
		var l: Lamp = _lamps[id]
		l.ghost = _ghost
		l.apply()


func get_lamps() -> Array:
	return _lamps.values()


## Метка точки (шарик) и направления (стрелка вдоль -Z источника). Видна по Shift+I
func _make_gizmo(cfg: LightConfig) -> Node3D:
	var root := Node3D.new()
	root.name = "LightGizmo_" + String(cfg.id)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = cfg.color
	mat.no_depth_test = true
	var ball := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.15
	sm.height = 0.3
	sm.material = mat
	ball.mesh = sm
	root.add_child(ball)
	if cfg.kind == LightConfig.Kind.SPOT:
		var arrow := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.03
		cm.bottom_radius = 0.03
		cm.height = 1.5
		cm.material = mat
		arrow.mesh = cm
		arrow.rotation_degrees = Vector3(90.0, 0.0, 0.0)
		arrow.position = Vector3(0.0, 0.0, -0.75)
		root.add_child(arrow)
	return root


func toggle_gizmos() -> void:
	_gizmos_on = not _gizmos_on
	for id in _lamp_order:
		var l: Lamp = _lamps[id]
		if l.gizmo and is_instance_valid(l.gizmo):
			l.gizmo.visible = _gizmos_on


## В Output: размеры кузова в системе корня модели (в ней же задаются position у LightConfig) и список источников
func print_layout() -> void:
	var vis := get_comp(C_Visual) as C_Visual
	if vis == null or vis.instance == null:
		return
	var lines: Array[String] = ["[Lights] %s. Оси корня модели: -Z нос, +Z хвост, +Y вверх, +X вправо по ходу" % entity.name]
	if not vis.mesh_nodes.is_empty() and vis.mesh_nodes[0].mesh:
		var m := vis.mesh_nodes[0]
		var b: AABB = (vis.instance.global_transform.affine_inverse() * m.global_transform) * m.mesh.get_aabb()
		lines.append("  кузов (mesh_nodes[0]): x %.2f..%.2f  y %.2f..%.2f  z %.2f..%.2f" % [
			b.position.x, b.end.x, b.position.y, b.end.y, b.position.z, b.end.z])
	for id in _lamp_order:
		var l: Lamp = _lamps[id]
		lines.append("  %s: pos %s rot %s %s" % [id, l.cfg.position, l.cfg.rotation_deg,
				"" if l.anchor != null and l.has_output() else "[NO LIGHT]"])
	print("\n".join(lines))


## Для вкладки Debug
func get_debug_info() -> Array[String]:
	var res: Array[String] = []
	for id in _order:
		var m: Mech = _mechs[id]
		var extra := ""
		if m.cfg.actuator == MechanismConfig.Actuator.ANIM and m.anim != null:
			var names := PackedStringArray()
			for e in m.anim_tracks:
				if not names.has(str((e.node as Node).name)):
					names.append(str((e.node as Node).name))
			extra = " ANIM узлы [%s] ошибка позы %.3f" % [", ".join(names), m.pose_error()]
		res.append("%s: t=%.2f -> %.2f %s%s%s" % [id, m.t, m.target,
				"" if m.found() else "[NO PART] ", "" if m.enabled else "[off]", extra])
	for id in _lamp_order:
		var l: Lamp = _lamps[id]
		res.append("light %s: t=%.2f -> %.2f gain %.2f power %s rule %s%s %s%s%s" % [id, l.t, l.target, l.gain,
				"%.2f" % l.power if l.uses_power() else "-",
				LightConfig.Rule.keys()[l.cfg.rule], " (manual)" if l.manual else "",
				"" if l.has_output() else "[NO LIGHT] ", "[culled] " if l.culled else "", "" if l.enabled else "[off]"])
	return res


# ==========================================
# ВРЕМЕННО, до вкладки в InfoPanel: O - переключить все механизмы выбранного вагона
# ==========================================

func _unhandled_input(event: InputEvent) -> void:
	if not Global.debug_mode or _ghost or (_mechs.is_empty() and _lamps.is_empty()) or not has_comp(C_Selected):
		return
	if Actions.pressed(event, &"mechanisms_toggle"):
		for id in _order:
			on_mechanism_toggle({"id": id})
	elif Actions.pressed(event, &"mechanisms_gizmos"):
		toggle_gizmos()
		print_layout()
	elif Actions.pressed(event, &"lights_toggle"):
		# все источники: если хоть один горит, гасим, иначе включаем
		var any_on := false
		for id in _lamp_order:
			any_on = any_on or _lamps[id].target > 0.5
		for id in _lamp_order:
			set_light(id, 0.0 if any_on else 1.0)


# ==========================================
# SAVE / LOAD
# ==========================================

func save_data() -> Dictionary:
	var d := {}
	for id in _order:
		var m: Mech = _mechs[id]
		d[String(id)] = {"t": m.t, "manual": m.manual, "enabled": m.enabled}
	var ld := {}
	for id in _lamp_order:
		var l: Lamp = _lamps[id]
		ld[String(id)] = {"t": l.t, "manual": l.manual, "enabled": l.enabled, "gain": l.gain}
	return {
		'comp_path': get_script().resource_path,
		'comp_name': get_script().resource_path.get_file().get_basename(),
		'mech': d,
		'lights': ld,
		'dir': _dir,
	}


## SaveManager зовёт после add_child, то есть после on_entity_ready: применяем сразу
func load_data(data: Dictionary) -> void:
	_saved = data.get('mech', {})
	_apply_saved()
	_saved_lights = data.get('lights', {})
	_dir = int(data.get('dir', 1))
	_apply_saved_lights()
	_drive_all(true)


func _apply_saved() -> void:
	for key in _saved.keys():
		var m: Mech = _mechs.get(StringName(key))
		if m == null:
			continue
		if m.linear:
			continue   # фазу ведёт колесо, из сейва её не берём
		var s: Dictionary = _saved[key]
		m.t = float(s.get("t", m.t))
		m.target = m.t
		m.manual = bool(s.get("manual", false))
		m.enabled = bool(s.get("enabled", m.enabled))
		m.apply()


func _apply_saved_lights() -> void:
	for key in _saved_lights.keys():
		var l: Lamp = _lamps.get(StringName(key))
		if l == null:
			continue
		var d: Dictionary = _saved_lights[key]
		l.t = float(d.get("t", l.t))
		l.target = l.t
		l.manual = bool(d.get("manual", false))
		l.enabled = bool(d.get("enabled", l.enabled))
		l.gain = clampf(float(d.get("gain", l.gain)), 0.0, LightConfig.GAIN_MAX)
		l.apply()
