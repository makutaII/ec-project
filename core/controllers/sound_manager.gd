extends Node

########################
## SND. Автолоад звука (ATTN_26)
########################
## Шины: Master, World, UI, Music, Ambience. Раскладка лежит в default_bus_layout.tres; если её нет или в ней
## нет нужной шины, шина создаётся здесь (запасной путь, в панели Audio редактора такая шина не видна).
## Файлы: load_stream(папка, имя, петля) ищет .wav, .ogg, .mp3, кэширует результат (и отсутствие файла).
## Голоса: C_Sound регистрируется здесь, раз в INTERVAL секунд ближайшие к камере (max_roll_voices штук)
## получают audible = true, остальные молчат (как GFX.light_budget для света).
## Стыки: allow_click() не пускает больше max_clicks_per_sec ударов в секунду на всю игру.

const INTERVAL := 0.25
const EXTENSIONS: Array[String] = ["wav", "ogg", "mp3"]
const BUSES: Array[StringName] = [&"World", &"UI", &"Music", &"Ambience"]

## Сколько сущностей одновременно играют качение (ближайшие к камере)
var max_roll_voices := 12
## Сколько ударов стыков в секунду на всю игру
var max_clicks_per_sec := 30
## Шина мира; если шины World нет, Master
var world_bus: StringName = &"World"

## Сколько сущностей слышимы после последней расстановки / сколько зарегистрировано (для отладки)
var audible_count := 0
var registered_count: int:
	get:
		return _sounds.size()

var _sounds: Array = []        # C_Sound
var _acc := 0.0
var _cache: Dictionary = {}    # ключ -> AudioStream или null (файла нет)
var _click_t := 0.0
var _click_n := 0


func _ready() -> void:
	_ensure_buses()


func _ensure_buses() -> void:
	for bus_name in BUSES:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, &"Master")
	if AudioServer.get_bus_index(world_bus) == -1:
		world_bus = &"Master"


## ------ Файлы ------

## Звук из папки по имени без расширения. null: имя пустое или файла нет (ошибки не будет).
## loop = true включает зацикливание в коде, а не настройками импорта (файлы не зависят от .import)
func load_stream(folder: String, base: StringName, loop: bool) -> AudioStream:
	if base == &"":
		return null
	var key := "%s/%s|%d" % [folder, base, int(loop)]
	if _cache.has(key):
		return _cache[key]
	var found: AudioStream = null
	for ext in EXTENSIONS:
		var path := "%s/%s.%s" % [folder, base, ext]
		if ResourceLoader.exists(path):
			var res := load(path) as AudioStream
			if res != null:
				# копия, чтобы флаг петли не менялся у общего ресурса
				found = res.duplicate() as AudioStream
				apply_loop(found, loop)
				break
	_cache[key] = found
	return found


## Сбросить кэш (после добавления файлов без перезапуска игры; уже созданные C_Sound звук не перечитывают)
func clear_cache() -> void:
	_cache.clear()


## Включить или выключить зацикливание всего файла. Для WAV границы петли в кадрах
func apply_loop(stream: AudioStream, loop: bool) -> void:
	if stream is AudioStreamWAV:
		var w := stream as AudioStreamWAV
		if loop:
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = int(w.get_length() * float(w.mix_rate))
		else:
			w.loop_mode = AudioStreamWAV.LOOP_DISABLED
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = loop
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = loop


## ------ Голоса ------

func register(sound: Node) -> void:
	if not _sounds.has(sound):
		_sounds.append(sound)
		_acc = INTERVAL   # расставить голоса в ближайшем кадре


func unregister(sound: Node) -> void:
	_sounds.erase(sound)


func _process(delta: float) -> void:
	_click_t += delta
	if _click_t >= 1.0:
		_click_t = 0.0
		_click_n = 0
	_acc += delta
	if _acc < INTERVAL:
		return
	_acc = 0.0
	rebalance()


## Ближайшие к камере max_roll_voices сущностей в пределах своего max_distance получают audible = true
func rebalance() -> void:
	var cam := get_viewport().get_camera_3d()
	var origin := cam.global_position if cam else Vector3.ZERO
	var cands: Array = []   # [расстояние^2, C_Sound]
	var alive: Array = []
	for s in _sounds:
		if not is_instance_valid(s):
			continue
		var cs := s as C_Sound
		if cs == null or cs.entity == null or not cs.entity.is_inside_tree():
			continue
		alive.append(cs)
		if not cs.is_active():
			cs.audible = false   # призрак стройки или удаляемая сущность не занимает голос
			continue
		var d2 := cs.entity.global_position.distance_squared_to(origin)
		var reach := cs.hearing_range()
		if reach <= 0.0 or d2 <= reach * reach:
			cands.append([d2, cs])
		else:
			cs.audible = false
	_sounds = alive
	cands.sort_custom(func(a, b): return a[0] < b[0])
	audible_count = 0
	for i in cands.size():
		var cs := cands[i][1] as C_Sound
		cs.audible = i < max_roll_voices
		if cs.audible:
			audible_count += 1


## ------ Стыки ------

## Бюджет ударов: false, если в эту секунду уже сыграно max_clicks_per_sec
func allow_click() -> bool:
	if _click_n >= max_clicks_per_sec:
		return false
	_click_n += 1
	return true


func reset_click_budget() -> void:
	_click_t = 0.0
	_click_n = 0
