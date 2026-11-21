class_name SoundCue extends Resource

########################
## Одиночный звук по событию (ATTN_26 §26.4, S2.1)
########################
## Файлы названы по имени без расширения и ищутся в SoundProfile.folder (как у остальных звуков профиля).
## Из найденных берётся случайный вариант. Нет ни одного из `files`: берутся `fallback_files`, чтобы звук был
## и с минимальным набором файлов. Нет и их: звука нет, ошибок нет.
## Громкость = gain_db + 20 * log10(сила / ref_strength), сила ограничена 0.1 .. 1.5 от ref_strength.

## Варианты файлов
@export var files: Array[StringName] = []
## Запасные файлы: играют, только если нет ни одного из `files`
@export var fallback_files: Array[StringName] = []
## Уровень при силе события, равной ref_strength, дБ
@export var gain_db: float = 0.0
## Сила события (скорость сближения, сила, скорость), при которой звук играет с gain_db
@export var ref_strength: float = 1.0
## Слабее этого события звука нет (0 = играет всегда). Сцепка шаблона состава приходит с силой 0 и молчит
@export var min_strength: float = 0.0
## Пауза между этим звуком у одной сущности, с
@export var cooldown: float = 0.1
## > 0: событие, которое приходит обоим вагонам пары, играет один раз в радиусе, м (0 = без отсечения)
@export var dedupe_radius: float = 0.0
## Разброс тона каждого удара (pitch_scale 1 ± значение)
@export var pitch_jitter: float = 0.05


## Быстрое создание для значений по умолчанию в SoundProfile
static func make(file_names: Array, fallback: Array, ref: float, cd: float, dedupe: float = 0.0,
		gain: float = 0.0, min_s: float = 0.0) -> SoundCue:
	var c := SoundCue.new()
	c.files.assign(file_names)
	c.fallback_files.assign(fallback)
	c.ref_strength = ref
	c.cooldown = cd
	c.dedupe_radius = dedupe
	c.gain_db = gain
	c.min_strength = min_s
	return c


## Громкость удара заданной силы, дБ
func volume_db(strength: float) -> float:
	return gain_db + linear_to_db(clampf(strength / maxf(ref_strength, 0.001), 0.1, 1.5))
