class_name SoundProfile extends Resource

########################
## Профиль звука вагона или локо (ATTN_26 §26.3.1)
########################
## Звуковые файлы названы по имени без расширения и ищутся в `folder` (.wav, .ogg, .mp3, в таком порядке).
## Профиль не держит ссылок на файлы: репозиторий собирается без звука (аудио не коммитится), а файл,
## который положили в папку с нужным именем, подхватывается при следующем запуске без правки ресурсов.
## Нет файла: этот звук молчит, ошибок нет.
## Пусто в WagonConfig.sound_profile: берётся SoundProfile.make_default(есть ли у сущности мотор): общий ресурс
## data/sounds/profiles/default_loco.tres (локо) или default_wagon.tres (вагон), если он есть, иначе значения по умолчанию.
## Подбор уровней: открыть этот .tres в Инспекторе и менять поля (при запущенной игре правки видны во вкладке Remote).

## Папка со звуками
@export_dir var folder: String = "res://data/sounds"

@export_group("Файлы")
## Качение колёс (петля)
@export var roll_loop: StringName = &"roll_loop"
## Стыки рельс (одиночные): на каждый стык играет случайный из списка
@export var joint_clicks: Array[StringName] = [&"joint_click_01", &"joint_click_02", &"joint_click_03"]
## Моторчик, холостой ход (питание есть, локо стоит): варианты, при каждом новом включении берётся случайный
@export var motor_idle_loops: Array[StringName] = [&"motor_idle_loop_01", &"motor_idle_loop_02", &"motor_idle_loop_03"]
## Моторчик на оборотах, без рельсов (петля). Тон идёт за оборотами вала
@export var motor_loop: StringName = &"motor_only_loop"
## Моторчик на оборотах вместе со звуком рельсов. Запасной вариант: играет, только если нет motor_loop
## (тогда качение у этого локо отдельно не добавляется, оно уже записано в этом файле)
@export var motor_roll_loop: StringName = &"motor_roll_loop"

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

@export_group("Моторчик")
## Уровень моторчика (обеих петель), дБ
@export var motor_gain_db: float = 0.0
## Добавка к уровню холостого хода, дБ: подгонка стыка холостой ход / обороты (кроссфейд)
@export var motor_idle_gain_db: float = 0.0
## Доля max_theoretical_speed, на которой записана петля motor_loop (тон 1.0). Обороты вала делятся на неё
@export var motor_ref_ratio: float = 0.5
## Пределы тона моторчика (pitch_scale)
@export var motor_pitch_min: float = 0.5
@export var motor_pitch_max: float = 1.6
## До какой доли оборотов холостой ход затихает, а петля оборотов нарастает (равная мощность)
@export var motor_idle_fade_ratio: float = 0.15

@export_group("Стыки")
## Уровень стыка, дБ
@export var joint_gain_db: float = 0.0
## Сила стыка (on_rail_joint.strength), при которой стык звучит с joint_gain_db
@export var joint_ref_strength: float = 1.0
## Пауза между стыками одной сущности, с
@export var joint_cooldown: float = 0.04

## Расстояние между осями тележки, м: после стыка идёт второй удар (двойной «тук-тук»: сигнал стыка приходит
## один на тележку, вторую ось добавляем задержкой gap / скорость). 0 = один удар
@export var joint_axle_gap: float = 2.0
## Второй удар тише первого на столько дБ
@export var joint_second_gain_db: float = -2.0
## Второй удар не играет, если до него дольше, с (на малой скорости оси далеко разнесены по времени)
@export var joint_second_max_delay: float = 0.5

@export_group("Одиночные звуки по событиям (S2.1)")
## Сцепка: v_close, м/с. Сила 0 (состав из шаблона, загрузка) молчит
@export var coupled: SoundCue = SoundCue.make([&"coupler_couple_01", &"coupler_couple_02", &"coupler_couple_03"], [], 1.0, 0.3, 24.0, 0.0, 0.05)
## Ручная расцепка
@export var uncoupled: SoundCue = SoundCue.make([&"coupler_release_01", &"coupler_release_02"], [&"coupler_couple_01", &"coupler_couple_02", &"coupler_couple_03"], 1.0, 0.3, 24.0)
## Обрыв сцепки: сила в Н
@export var coupler_broken: SoundCue = SoundCue.make([&"coupler_break_01"], [&"coupler_impact_01", &"coupler_impact_02", &"coupler_impact_03"], 30.0, 0.5, 24.0)
## Удар буферов вагона о вагон: v_close, м/с
@export var coupler_impact: SoundCue = SoundCue.make([&"coupler_impact_01", &"coupler_impact_02", &"coupler_impact_03"], [], 1.5, 0.2, 24.0)
## Удар о препятствие или тупик: v_close, м/с
@export var obstacle_impact: SoundCue = SoundCue.make([&"obstacle_impact_01", &"obstacle_impact_02"], [&"coupler_impact_01", &"coupler_impact_02", &"coupler_impact_03"], 1.5, 0.3)
## Лязг слабины сцепки: сила в Н; играет, когда сила переходит порог min_strength (слабину выбрали)
@export var coupler_clank: SoundCue = SoundCue.make([&"coupler_clank_01", &"coupler_clank_02", &"coupler_clank_03"], [&"coupler_impact_01", &"coupler_impact_02", &"coupler_impact_03"], 20.0, 0.35, 24.0, 0.0, 3.0)
## Сход с рельсов: скорость, м/с
@export var derailed: SoundCue = SoundCue.make([&"derail_01", &"derail_02"], [], 3.0, 1.0)
## Пинок игрока: |power_kick|, м/с (заряженный пинок 2…50)
@export var kicked: SoundCue = SoundCue.make([&"kick_01"], [&"wagon_set_01", &"wagon_set_02", &"wagon_set_03"], 20.0, 0.2)
## Посадка вагона на рельсы после перетаскивания
@export var snapped: SoundCue = SoundCue.make([&"wagon_set_01", &"wagon_set_02", &"wagon_set_03"], [], 1.0, 0.2, 0.0, -3.0)

@export_group("Источник в пространстве")
## AudioStreamPlayer3D.unit_size: расстояние, на котором звук ещё не ослаблен
@export var unit_size: float = 10.0
## AudioStreamPlayer3D.max_distance: дальше звука нет (0 = без предела). Совпадает с радиусом, в котором SND считает сущность слышимой
@export var max_distance: float = 60.0


const DEFAULT_LOCO := "res://data/sounds/profiles/default_loco.tres"
const DEFAULT_WAGON := "res://data/sounds/profiles/default_wagon.tres"


## Профиль по умолчанию: общий ресурс из data/sounds/profiles, если он есть, иначе новый.
## У локо качение громче, у вагона на 6 дБ тише (ATTN_26 §26.6.3)
static func make_default(is_loco: bool) -> SoundProfile:
	var path := DEFAULT_LOCO if is_loco else DEFAULT_WAGON
	if ResourceLoader.exists(path):
		var shared := load(path) as SoundProfile
		if shared != null:
			return shared
	var p := SoundProfile.new()
	p.roll_gain_db = 0.0 if is_loco else -6.0
	return p
