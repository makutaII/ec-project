class_name SoundProfile extends Resource

########################
## Профиль звука вагона или локо (ATTN_26 §26.3.1)
########################
## Звуковые файлы названы по имени без расширения и ищутся в `folder` (.wav, .ogg, .mp3, в таком порядке).
## Профиль не держит ссылок на файлы: репозиторий собирается без звука (аудио не коммитится), а файл,
## который положили в папку с нужным именем, подхватывается при следующем запуске без правки ресурсов.
## Нет файла: этот звук молчит, ошибок нет.
## Пусто в WagonConfig.sound_profile: берётся SoundProfile.make_default(есть ли у сущности мотор).

## Папка со звуками
@export_dir var folder: String = "res://data/sounds"

@export_group("Файлы")
## Качение колёс (петля)
@export var roll_loop: StringName = &"roll_loop"
## Стыки рельс (одиночные): на каждый стык играет случайный из списка
@export var joint_clicks: Array[StringName] = [&"joint_click_01", &"joint_click_02", &"joint_click_03"]

@export_group("Качение")
## Уровень качения, дБ. У вагона ниже, чем у локо (SoundProfile.make_default)
@export var roll_gain_db: float = 0.0
## Скорость, м/с, при которой петля качения звучит с тоном 1.0 и громкостью roll_gain_db. Ниже тише, выше громче
@export var roll_ref_speed: float = 8.0
## Ниже этой скорости, м/с, качения нет (плавный спад)
@export var roll_min_speed: float = 0.05
## Пределы тона качения (pitch_scale)
@export var roll_pitch_min: float = 0.5
@export var roll_pitch_max: float = 1.6

@export_group("Стыки")
## Уровень стыка, дБ
@export var joint_gain_db: float = 0.0
## Сила стыка (on_rail_joint.strength), при которой стык звучит с joint_gain_db
@export var joint_ref_strength: float = 1.0
## Пауза между стыками одной сущности, с
@export var joint_cooldown: float = 0.04

@export_group("Источник в пространстве")
## AudioStreamPlayer3D.unit_size: расстояние, на котором звук ещё не ослаблен
@export var unit_size: float = 10.0
## AudioStreamPlayer3D.max_distance: дальше звука нет (0 = без предела). Совпадает с радиусом, в котором SND считает сущность слышимой
@export var max_distance: float = 60.0


## Профиль по умолчанию: у локо качение громче, у вагона на 6 дБ тише (ATTN_26 §26.6.3)
static func make_default(is_loco: bool) -> SoundProfile:
	var p := SoundProfile.new()
	p.roll_gain_db = 0.0 if is_loco else -6.0
	return p
