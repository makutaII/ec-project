class_name C_Sound extends ICapability

####################
## Способность. Звук сущности (ATTN_26 §26.5, §26.6): качение колёс, стыки рельс и моторчик (этапы S1.2, S1.3)
####################
## Профиль: WagonConfig.sound_profile, пусто = SoundProfile.make_default(есть ли у сущности C_Engine).
## Качение: одна петля roll_loop на сущность, тон и громкость идут за |C_Chassis.current_speed|, пока вагон
## на рельсах и движется; остановился, сошёл с рельсов или далеко от камеры: плавный спад и stop().
## Стыки: on_rail_joint {bogie, kind, strength} -> случайный из joint_clicks, громкость от strength.
## Моторчик (только у сущности с C_Engine): две петли с кроссфейдом равной мощности по оборотам вала
##   r = |C_Chassis.get_motor_speed()| / C_Engine.max_theoretical_speed:
##   холостой ход (motor_idle_loops, случайный вариант при каждом включении) на r около 0 и петля оборотов
##   (motor_loop, тон от r) выше motor_idle_fade_ratio. Звучит, пока on_force_changed.powered и сущность на рельсах.
##   Нет motor_loop, но есть motor_roll_loop: он играет вместо неё, а отдельное качение у этого локо не играет.
## Голоса: SND.register(self); SND раз в 0.25 с ставит audible только ближайшим к камере (лимит SND.max_roll_voices).
## Нет файла в data/sounds: этот звук молчит, ошибок нет.
## Источники AudioStreamPlayer3D становятся детьми Entity (компонент это Node, а не Node3D, позиции у него нет).
## Порядок в components: после Chassis и Engine (читает их в физическом кадре)

const SILENT_DB := -60.0       # тише этого петля не играет
const FADE_UP_DB_S := 200.0    # скорость нарастания, дБ/с
const FADE_DOWN_DB_S := 90.0   # скорость спада, дБ/с


## Один голос-петля: плавная громкость, случайный вариант и случайный старт при каждом включении
class Voice extends RefCounted:
	var node_name: String
	var streams: Array[AudioStream] = []   # варианты; пусто: голоса нет
	var player: AudioStreamPlayer3D
	var db := -80.0
	var pitch := 1.0

	func _init(player_name: String) -> void:
		node_name = player_name

	func available() -> bool:
		return not streams.is_empty()

	## target_db = -80: тишина (спад до SILENT_DB, затем stop)
	func update(host: C_Sound, delta: float, target_db: float, new_pitch: float) -> void:
		if streams.is_empty():
			return
		var rate := C_Sound.FADE_UP_DB_S if target_db > db else C_Sound.FADE_DOWN_DB_S
		db = move_toward(db, target_db, rate * delta)
		if db <= C_Sound.SILENT_DB:
			if is_instance_valid(player) and player.playing:
				player.stop()
			return
		pitch = new_pitch
		var p := _ensure(host)
		p.volume_db = db
		p.pitch_scale = pitch
		if not p.playing:
			p.stream = streams[randi() % streams.size()]
			# со случайного места петли: вагоны не стартуют в унисон
			p.play(randf() * maxf(p.stream.get_length() - 0.1, 0.0))

	func free_player() -> void:
		if is_instance_valid(player):
			player.queue_free()
		player = null

	func _ensure(host: C_Sound) -> AudioStreamPlayer3D:
		if is_instance_valid(player):
			return player
		var prof := host.profile
		player = AudioStreamPlayer3D.new()
		player.name = node_name
		player.stream = streams[0]
		player.bus = SND.world_bus
		player.unit_size = prof.unit_size
		player.max_distance = prof.max_distance
		host.entity.add_child(player)
		return player


## Профиль звука. Задаёт SoundSetting; пусто: по умолчанию при on_entity_ready
var profile: SoundProfile
## Слышима ли сущность: ставит SND (ближайшие к камере в пределах max_distance)
var audible := false

var _chassis: C_Chassis
var _engine: C_Engine
var _roll := Voice.new("SndRoll")
var _motor_idle := Voice.new("SndMotorIdle")
var _motor_run := Voice.new("SndMotorRun")
var _roll_suppressed := false          # рельсы уже записаны в петле моторчика (motor_roll_loop)
var _click_streams: Array[AudioStream] = []
var _powered := false                  # из on_force_changed
var _click_cd := 0.0
# Свои на каждый вагон: одинаковые вагоны иначе складываются в «гребёнку» (ATTN_26 §26.6.3)
var _pitch_jitter := 1.0
var _db_jitter := 0.0


## Обороты вала как доля предела мотора, 0..1.5
static func motor_ratio(shaft_speed: float, max_speed: float) -> float:
	return clampf(absf(shaft_speed) / maxf(max_speed, 0.001), 0.0, 1.5)


## Веса (холостой ход, обороты) по оборотам r. Равная мощность: cos и sin. Нет одной из петель: вторая звучит всегда
static func motor_mix(r: float, fade_ratio: float, has_idle: bool, has_run: bool) -> Vector2:
	if not has_run:
		return Vector2(1.0, 0.0)
	if not has_idle:
		return Vector2(0.0, 1.0)
	var a := smoothstep(0.0, maxf(fade_ratio, 0.001), r)
	return Vector2(cos(a * PI * 0.5), sin(a * PI * 0.5))


func on_entity_ready() -> void:
	_chassis = get_comp(C_Chassis) as C_Chassis
	_engine = get_comp(C_Engine) as C_Engine
	if profile == null:
		profile = SoundProfile.make_default(_engine != null)
	var roll := SND.load_stream(profile.folder, profile.roll_loop, true)
	if roll != null:
		_roll.streams.append(roll)
	for n in profile.joint_clicks:
		var s := SND.load_stream(profile.folder, n, false)
		if s != null:
			_click_streams.append(s)
	if _engine != null:
		for n in profile.motor_idle_loops:
			var s := SND.load_stream(profile.folder, n, true)
			if s != null:
				_motor_idle.streams.append(s)
		var run := SND.load_stream(profile.folder, profile.motor_loop, true)
		if run == null:
			run = SND.load_stream(profile.folder, profile.motor_roll_loop, true)
			_roll_suppressed = run != null
		if run != null:
			_motor_run.streams.append(run)
	_pitch_jitter = randf_range(0.97, 1.03)
	_db_jitter = randf_range(-1.0, 1.0)
	SND.register(self)


func on_removed() -> void:
	SND.unregister(self)
	_roll.free_player()
	_motor_idle.free_player()
	_motor_run.free_player()


func _exit_tree() -> void:
	SND.unregister(self)


## Радиус, в котором сущность может звучать (0 = без предела). Читает SND
func hearing_range() -> float:
	return profile.max_distance if profile != null else 0.0


## ⚡ C_Engine шлёт каждый физический кадр: питание есть или нет. Силу и напряжение берём у самого C_Engine
func on_force_changed(data: Dictionary) -> void:
	_powered = bool(data.get("powered", false))


## ⚡ Стык рельс от C_Chassis: короткий удар. Событие редкое, словарь не страшен.
func on_rail_joint(data: Dictionary) -> void:
	if _click_streams.is_empty() or not audible or _click_cd > 0.0 or not is_active():
		return
	if not SND.allow_click():
		return
	_click_cd = profile.joint_cooldown
	var strength := float(data.get("strength", 1.0))
	var k := clampf(strength / maxf(profile.joint_ref_strength, 0.001), 0.1, 1.5)
	var p := AudioStreamPlayer3D.new()
	p.stream = _click_streams[randi() % _click_streams.size()]
	p.bus = SND.world_bus
	p.unit_size = profile.unit_size
	p.max_distance = profile.max_distance
	p.volume_db = profile.joint_gain_db + _db_jitter + linear_to_db(k)
	p.pitch_scale = randf_range(0.95, 1.05)
	p.finished.connect(p.queue_free)
	entity.add_child(p)
	p.play()


func _physics_process(delta: float) -> void:
	if _click_cd > 0.0:
		_click_cd -= delta
	var live := audible and is_active()
	_update_roll(delta, live)
	_update_motor(delta, live)


func _update_roll(delta: float, live: bool) -> void:
	if not _roll.available():
		return
	var target_db := -80.0
	var pitch := _roll.pitch
	if live and not _roll_suppressed and _is_rolling():
		var k := absf(_chassis.current_speed) / maxf(profile.roll_ref_speed, 0.001)
		target_db = profile.roll_gain_db + _db_jitter + linear_to_db(clampf(k, 0.001, 1.5))
		pitch = clampf(k, profile.roll_pitch_min, profile.roll_pitch_max) * _pitch_jitter
	_roll.update(self, delta, target_db, pitch)


## Моторчик: холостой ход и обороты по оборотам вала (§26.5.1)
func _update_motor(delta: float, live: bool) -> void:
	if _engine == null or _chassis == null:
		return
	var has_idle := _motor_idle.available()
	var has_run := _motor_run.available()
	if not has_idle and not has_run:
		return
	var idle_db := -80.0
	var run_db := -80.0
	var run_pitch := _motor_run.pitch
	if live and _powered and _chassis.is_on_rails:
		var r := motor_ratio(_chassis.get_motor_speed(), _engine.max_theoretical_speed)
		var w := motor_mix(r, profile.motor_idle_fade_ratio, has_idle, has_run)
		idle_db = profile.motor_gain_db + linear_to_db(maxf(w.x, 0.001))
		run_db = profile.motor_gain_db + linear_to_db(maxf(w.y, 0.001))
		run_pitch = clampf(r / maxf(profile.motor_ref_ratio, 0.001), profile.motor_pitch_min, profile.motor_pitch_max)
	_motor_idle.update(self, delta, idle_db, 1.0)
	_motor_run.update(self, delta, run_db, run_pitch)


## Вагон на рельсах и движется
func _is_rolling() -> bool:
	return _chassis != null and _chassis.is_on_rails and absf(_chassis.current_speed) > profile.roll_min_speed and is_active()


## Не призрак (стройка) и не удаляется. Неактивные SND в голосах не считает
func is_active() -> bool:
	return entity != null and not entity.is_queued_for_deletion() and not entity.has_comp(C_Ghost)
