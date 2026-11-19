class_name C_Sound extends ICapability

####################
## Способность. Звук сущности (ATTN_26 §26.5, §26.6): качение колёс и стыки рельс (этап S1.2)
####################
## Профиль: WagonConfig.sound_profile, пусто = SoundProfile.make_default(есть ли у сущности C_Engine).
## Качение: одна петля roll_loop на сущность, тон и громкость идут за |C_Chassis.current_speed|, пока вагон
## на рельсах и движется; остановился, сошёл с рельсов или далеко от камеры: плавный спад и stop().
## Стыки: on_rail_joint {bogie, kind, strength} -> случайный из joint_clicks, громкость от strength.
## Голоса: SND.register(self); SND раз в 0.25 с ставит audible только ближайшим к камере (лимит SND.max_roll_voices).
## Нет файла в data/sounds: этот звук молчит, ошибок нет.
## Источники AudioStreamPlayer3D становятся детьми Entity (компонент это Node, а не Node3D, позиции у него нет).
## Порядок в components: после Chassis и Engine (читает их в физическом кадре)

const SILENT_DB := -60.0       # тише этого петля не играет
const FADE_UP_DB_S := 200.0    # скорость нарастания, дБ/с
const FADE_DOWN_DB_S := 90.0   # скорость спада, дБ/с

## Профиль звука. Задаёт SoundSetting; пусто: по умолчанию при on_entity_ready
var profile: SoundProfile
## Слышима ли сущность: ставит SND (ближайшие к камере в пределах max_distance)
var audible := false

var _chassis: C_Chassis
var _roll: AudioStreamPlayer3D
var _roll_stream: AudioStream
var _click_streams: Array[AudioStream] = []
var _roll_db := -80.0
var _pitch := 1.0
var _click_cd := 0.0
# Свои на каждый вагон: одинаковые вагоны иначе складываются в «гребёнку» (ATTN_26 §26.6.3)
var _pitch_jitter := 1.0
var _db_jitter := 0.0


func on_entity_ready() -> void:
	_chassis = get_comp(C_Chassis) as C_Chassis
	if profile == null:
		profile = SoundProfile.make_default(has_comp(C_Engine))
	_roll_stream = SND.load_stream(profile.folder, profile.roll_loop, true)
	for n in profile.joint_clicks:
		var s := SND.load_stream(profile.folder, n, false)
		if s != null:
			_click_streams.append(s)
	_pitch_jitter = randf_range(0.97, 1.03)
	_db_jitter = randf_range(-1.0, 1.0)
	SND.register(self)


func on_removed() -> void:
	SND.unregister(self)
	if is_instance_valid(_roll):
		_roll.queue_free()


func _exit_tree() -> void:
	SND.unregister(self)


## Радиус, в котором сущность может звучать (0 = без предела). Читает SND
func hearing_range() -> float:
	return profile.max_distance if profile != null else 0.0


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
	if _roll_stream == null:
		return
	var target_db := -80.0
	if audible and _is_rolling():
		var k := absf(_chassis.current_speed) / maxf(profile.roll_ref_speed, 0.001)
		target_db = profile.roll_gain_db + _db_jitter + linear_to_db(clampf(k, 0.001, 1.5))
		_pitch = clampf(k, profile.roll_pitch_min, profile.roll_pitch_max) * _pitch_jitter
	var rate := FADE_UP_DB_S if target_db > _roll_db else FADE_DOWN_DB_S
	_roll_db = move_toward(_roll_db, target_db, rate * delta)
	if _roll_db <= SILENT_DB:
		if is_instance_valid(_roll) and _roll.playing:
			_roll.stop()
		return
	var p := _ensure_roll_player()
	p.volume_db = _roll_db
	p.pitch_scale = _pitch
	if not p.playing:
		# со случайного места петли: вагоны не стартуют в унисон
		p.play(randf() * maxf(_roll_stream.get_length() - 0.1, 0.0))


## Вагон на рельсах и движется
func _is_rolling() -> bool:
	return _chassis != null and _chassis.is_on_rails and absf(_chassis.current_speed) > profile.roll_min_speed and is_active()


## Не призрак (стройка) и не удаляется. Неактивные SND в голосах не считает
func is_active() -> bool:
	return entity != null and not entity.is_queued_for_deletion() and not entity.has_comp(C_Ghost)


func _ensure_roll_player() -> AudioStreamPlayer3D:
	if is_instance_valid(_roll):
		return _roll
	_roll = AudioStreamPlayer3D.new()
	_roll.name = "SndRoll"
	_roll.stream = _roll_stream
	_roll.bus = SND.world_bus
	_roll.unit_size = profile.unit_size
	_roll.max_distance = profile.max_distance
	entity.add_child(_roll)
	return _roll
