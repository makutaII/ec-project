extends Node

## Проверка звука (ATTN_26 S1.0-S1.3, S2.1): шины, профиль, поиск файлов, петли, моторчик, расстановка голосов, стыки,
## одиночные звуки по событиям.
## Запуск: открыть tests/sound_test.tscn и нажать F6. Итог в Output: строки PASS/FAIL и «Sound: n/m».
## Звуковые файлы не нужны: тест работает без data/sounds, поток для петель и стыков собирается кодом.

var _ok := 0
var _all := 0


func _ready() -> void:
	_test_buses()
	_test_profile()
	_test_streams()
	await _test_motor()
	await _test_voices()
	await _test_clicks()
	await _test_cues()
	print("Sound: %d/%d" % [_ok, _all])
	get_tree().quit(0 if _ok == _all else 1)


func _test_buses() -> void:
	for n in [&"World", &"UI", &"Music", &"Ambience"]:
		_check("Шины: %s есть" % n, AudioServer.get_bus_index(n) != -1)
	_check("Шины: шина мира это World", SND.world_bus == &"World")


func _test_profile() -> void:
	var loco := SoundProfile.make_default(true)
	var wagon := SoundProfile.make_default(false)
	_check("Профиль: у вагона качение тише, чем у локо", wagon.roll_gain_db < loco.roll_gain_db)
	_check("Профиль: по умолчанию три варианта стыка и петля качения",
		loco.joint_clicks.size() == 3 and loco.roll_loop == &"roll_loop")
	_check("Профиль: папка звуков data/sounds", loco.folder == "res://data/sounds")
	_check("Профиль: общие ресурсы по умолчанию есть (data/sounds/profiles) и грузятся",
		ResourceLoader.exists(SoundProfile.DEFAULT_LOCO) and ResourceLoader.exists(SoundProfile.DEFAULT_WAGON)
		and load(SoundProfile.DEFAULT_WAGON) is SoundProfile)
	_check("Профиль: моторчик по умолчанию (три холостых, motor_only_loop, motor_roll_loop)",
		loco.motor_idle_loops.size() == 3 and loco.motor_loop == &"motor_only_loop" and loco.motor_roll_loop == &"motor_roll_loop")


func _test_streams() -> void:
	_check("Файлы: нет файла, null и без ошибки", SND.load_stream("res://data/sounds", &"no_such_file_x", true) == null)
	_check("Файлы: пустое имя, null", SND.load_stream("res://data/sounds", &"", false) == null)
	var w := _make_stream()
	SND.apply_loop(w, true)
	_check("Петля: WAV зациклен на весь файл (loop_end = 8000 кадров)",
		w.loop_mode == AudioStreamWAV.LOOP_FORWARD and w.loop_begin == 0 and w.loop_end == 8000)
	SND.apply_loop(w, false)
	_check("Петля: выключение возвращает LOOP_DISABLED", w.loop_mode == AudioStreamWAV.LOOP_DISABLED)
	var ogg := AudioStreamOggVorbis.new()
	SND.apply_loop(ogg, true)
	_check("Петля: OGG зациклен флагом loop", ogg.loop)


func _test_motor() -> void:
	_check("Моторчик: обороты вала, доля предела", is_equal_approx(C_Sound.motor_ratio(-3.0, 6.0), 0.5))
	_check("Моторчик: обороты ограничены сверху (1.5) и защищены от нулевого предела",
		is_equal_approx(C_Sound.motor_ratio(60.0, 6.0), 1.5) and C_Sound.motor_ratio(1.0, 0.0) <= 1.5)
	var stand := C_Sound.motor_mix(0.0, 0.15, true, true)
	_check("Моторчик: на стоянке звучит только холостой ход", is_equal_approx(stand.x, 1.0) and is_equal_approx(stand.y, 0.0))
	var fast := C_Sound.motor_mix(0.5, 0.15, true, true)
	_check("Моторчик: на оборотах звучит только петля оборотов", is_equal_approx(fast.y, 1.0) and absf(fast.x) < 0.001)
	var mid := C_Sound.motor_mix(0.075, 0.15, true, true)
	_check("Моторчик: в середине перехода мощность суммы постоянна (cos и sin)", is_equal_approx(mid.x * mid.x + mid.y * mid.y, 1.0))
	_check("Моторчик: без петли оборотов всегда холостой, без холостого всегда обороты",
		C_Sound.motor_mix(0.5, 0.15, true, false) == Vector2(1.0, 0.0) and C_Sound.motor_mix(0.0, 0.15, false, true) == Vector2(0.0, 1.0))

	var c := _spawn(Vector3(0, 0, 0))
	c._roll.streams.append(_make_stream())
	c._roll.update(c, 0.1, -10.0, 1.0)
	_check("Голос: тихая громкость (ниже порога) источник не создаёт", not is_instance_valid(c._roll.player))
	c._roll.update(c, 1.0, -10.0, 1.2)
	var p := c._roll.player
	_check("Голос: после нарастания создан источник SndRoll с нужной громкостью и тоном",
		is_instance_valid(p) and p.name == "SndRoll" and absf(p.volume_db + 10.0) < 0.01 and is_equal_approx(p.pitch_scale, 1.2))
	c._roll.update(c, 1.0, -80.0, 1.2)
	_check("Голос: после спада громкость ниже порога тишины", c._roll.db <= C_Sound.SILENT_DB)
	c.entity.queue_free()
	await get_tree().process_frame


func _test_cues() -> void:
	var cue := SoundCue.make([&"a"], [&"b"], 2.0, 0.1, 0.0, -3.0, 0.5)
	_check("Звук по событию: сила равна ref_strength, громкость равна gain_db", is_equal_approx(cue.volume_db(2.0), -3.0))
	_check("Звук по событию: сила вдвое больше ref ограничена +3.5 дБ, нулевая даёт -20 дБ",
		absf(cue.volume_db(10.0) - (-3.0 + linear_to_db(1.5))) < 0.001 and absf(cue.volume_db(0.0) - (-3.0 - 20.0)) < 0.001)
	var prof := SoundProfile.make_default(false)
	_check("Звук по событию: у профиля по умолчанию заданы все звуки S2.1",
		prof.coupled != null and prof.uncoupled != null and prof.coupler_broken != null and prof.coupler_impact != null
		and prof.obstacle_impact != null and prof.coupler_clank != null and prof.derailed != null and prof.kicked != null and prof.snapped != null)
	_check("Звук по событию: сцепка с v_close 0 (шаблон состава) молчит по min_strength", prof.coupled.min_strength > 0.0)

	SND.reset_claims()
	_check("Повтор события пары: первый звук проходит", SND.claim(&"t_pair", Vector3.ZERO, 10.0))
	_check("Повтор события пары: второй рядом отсечён", not SND.claim(&"t_pair", Vector3(5, 0, 0), 10.0))
	_check("Повтор события пары: дальше радиуса, другой ключ проходят",
		SND.claim(&"t_pair", Vector3(50, 0, 0), 10.0) and SND.claim(&"t_other", Vector3(5, 0, 0), 10.0))
	SND.reset_claims()

	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	_check("Дальность: за пределами слышимости источник не создаётся",
		SND.too_far(Vector3(500, 0, 0), 60.0) and not SND.too_far(Vector3(5, 0, 0), 60.0) and not SND.too_far(Vector3(500, 0, 0), 0.0))

	var c := _spawn(Vector3(3, 0, 0))
	await get_tree().process_frame
	var s := _make_stream()
	for cu in [c.profile.coupled, c.profile.uncoupled, c.profile.coupler_impact, c.profile.obstacle_impact,
			c.profile.coupler_clank, c.profile.derailed, c.profile.kicked, c.profile.snapped]:
		c._cue_streams[cu] = [s]
	var base := c.entity.get_child_count()

	c.on_coupled({"other": null, "end": 0, "v_close": 0.0})
	_check("Сцепка: v_close 0 звука не даёт", c.entity.get_child_count() == base)
	SND.reset_claims()
	c.on_coupled({"other": null, "end": 0, "v_close": 1.0})
	_check("Сцепка: на скорости сближения играет один источник", c.entity.get_child_count() == base + 1)
	c.on_coupled({"other": null, "end": 0, "v_close": 1.0})
	_check("Сцепка: повтор сразу отсекает пауза", c.entity.get_child_count() == base + 1)

	c.on_coupler_released({"reason": &"separated"})
	_check("Расцепка: не ручная причина звука не даёт", c.entity.get_child_count() == base + 1)
	SND.reset_claims()
	c.on_coupler_released({"reason": &"manual"})
	_check("Расцепка: ручная играет", c.entity.get_child_count() == base + 2)

	SND.reset_claims()
	c.on_coupler_impact({"v_close": 1.0, "dv": 0.0, "derailed": false})
	c.on_coupler_impact({"v_close": 1.0, "dv": 0.0, "derailed": false, "obstacle": true})
	_check("Удар: вагон о вагон и о препятствие играют разными звуками (свои паузы)", c.entity.get_child_count() == base + 4)

	SND.reset_claims()
	c.on_coupler_force({"force": 1.0})
	_check("Лязг: слабая сила ниже порога звука не даёт", c.entity.get_child_count() == base + 4)
	c.on_coupler_force({"force": 10.0})
	_check("Лязг: переход через порог играет", c.entity.get_child_count() == base + 5)
	c.on_coupler_force({"force": 12.0})
	_check("Лязг: сила остаётся выше порога, звука повторно нет", c.entity.get_child_count() == base + 5)

	c.on_derailed({"reason": "hi speed", "current_velocity_3d": Vector3(4, 0, 0)})
	c.on_train_kicked({"power_kick": -10.0})
	c.on_train_snapped({})
	_check("Сход, пинок и посадка на рельсы играют по одному источнику", c.entity.get_child_count() == base + 8)

	# вторые удары стыков: задержка выходит, звук играет, очередь пустеет
	c._click_streams.append(s)
	c.audible = true
	c._pending.append([0.0, -10.0])
	var before := c.entity.get_child_count()
	c._physics_process(0.016)
	_check("Стыки: второй удар играет по истечении задержки, очередь пустеет",
		c.entity.get_child_count() == before + 1 and c._pending.is_empty())
	c._pending.append([1.0, -10.0])
	c._physics_process(0.016)
	_check("Стыки: второй удар до своего времени не играет", c.entity.get_child_count() == before + 1 and c._pending.size() == 1)

	c.entity.queue_free()
	cam.queue_free()
	await get_tree().process_frame


func _test_voices() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	cam.global_position = Vector3.ZERO
	var comps: Array[C_Sound] = []
	for i in 20:
		comps.append(_spawn(Vector3(float(i) * 2.0 + 1.0, 0, 0)))
	await get_tree().process_frame
	SND.rebalance()
	var near_ok := true
	for i in 12:
		near_ok = near_ok and comps[i].audible
	var far_ok := true
	for i in range(12, 20):
		far_ok = far_ok and not comps[i].audible
	_check("Голоса: слышимых ровно %d (лимит SND)" % SND.max_roll_voices, SND.audible_count == SND.max_roll_voices)
	_check("Голоса: слышимы 12 ближайших к камере, остальные молчат", near_ok and far_ok)

	cam.global_position = Vector3(38.0, 0, 0)
	SND.rebalance()
	_check("Голоса: камера переехала, слышимыми стали ближайшие к новой точке", comps[19].audible and not comps[0].audible)

	var far := _spawn(Vector3(500.0, 0, 0))
	SND.rebalance()
	_check("Голоса: дальше max_distance сущность не слышима", not far.audible)

	var before := SND.registered_count
	comps[0].entity.free()
	await get_tree().process_frame
	_check("Голоса: удалённая сущность снимается с учёта", SND.registered_count == before - 1)

	for c in comps:
		if is_instance_valid(c) and is_instance_valid(c.entity):
			c.entity.queue_free()
	if is_instance_valid(far.entity):
		far.entity.queue_free()
	cam.queue_free()
	await get_tree().process_frame


func _test_clicks() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	var c := _spawn(Vector3(3, 0, 0))
	c._click_streams.append(_make_stream())
	await get_tree().process_frame
	SND.rebalance()
	_check("Стыки: рядом с камерой сущность слышима", c.audible)

	var base := c.entity.get_child_count()
	c.on_rail_joint({"bogie": 0, "kind": &"track", "strength": 1.0})
	_check("Стыки: на стык создан один источник", c.entity.get_child_count() == base + 1)
	c.on_rail_joint({"bogie": 1, "kind": &"track", "strength": 1.0})
	_check("Стыки: второй стык сразу следом отсекает пауза (cooldown)", c.entity.get_child_count() == base + 1)

	c._click_cd = 0.0
	c.audible = false
	c.on_rail_joint({"bogie": 0, "kind": &"track", "strength": 1.0})
	_check("Стыки: неслышимая сущность стыки не играет", c.entity.get_child_count() == base + 1)

	c.audible = true
	var empty := _spawn(Vector3(4, 0, 0))
	empty.audible = true
	var empty_base := empty.entity.get_child_count()
	empty.on_rail_joint({"bogie": 0, "kind": &"track", "strength": 1.0})
	_check("Стыки: нет файлов, событие обходится без ошибок и без источников", empty.entity.get_child_count() == empty_base)

	SND.reset_click_budget()
	var passed := 0
	for i in 100:
		if SND.allow_click():
			passed += 1
	_check("Стыки: бюджет пускает max_clicks_per_sec ударов в секунду", passed == SND.max_clicks_per_sec)
	SND.reset_click_budget()

	c.entity.queue_free()
	empty.entity.queue_free()
	cam.queue_free()
	await get_tree().process_frame


## Сущность с одним C_Sound на заданном месте. Без C_Chassis: качения нет, голоса и стыки работают
func _spawn(pos: Vector3) -> C_Sound:
	var e := Entity.new()
	var c := C_Sound.new()
	c.name = "C_Sound"
	e.add_component(c)
	add_child(e)
	e.global_position = pos
	return c


## WAV 8000 Гц, 1 с, 16 бит, моно, тишина (звука нет, нужен поток)
func _make_stream() -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = 8000
	w.stereo = false
	var data := PackedByteArray()
	data.resize(8000 * 2)
	w.data = data
	return w


func _check(title: String, cond: bool) -> void:
	_all += 1
	if cond:
		_ok += 1
		print("PASS ", title)
	else:
		print("FAIL ", title)
