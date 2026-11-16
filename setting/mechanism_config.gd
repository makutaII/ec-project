class_name MechanismConfig extends Resource

########################
## Описание одного механизма вагона/локо. Массив лежит в WagonConfig.mechanisms.
########################
## Сейчас реализованы: source = COMMAND, actuator = SLIDE / ROTATE / ANIM.
## Остальное - заготовки под следующие шаги (дышла, фары, дым, вентилятор, пантограф).

enum Source { COMMAND, WHEEL_PHASE, SPEED, POWERED, DIRECTION }
## ANIM (0_ATTN_24 §24.6): движение ведёт анимация из .glb (Blender Action), состояние 0..1 это время между первым и последним ключом.
## ANIM добавлен в конец списка: числа остальных значений в .tres не меняются
enum Actuator { SLIDE, ROTATE, SPIN, CLIP, LIGHT, PARTICLES, ANIM }

@export var id: StringName = &"door_left"
## Подпись для InfoPanel
@export var title: String = "Дверь"

@export_category("Что и как двигается")
@export var source: Source = Source.COMMAND
@export var actuator: Actuator = Actuator.SLIDE

## Роль подвижной части (Custom Property "role" в Blender, либо имя узла). У ANIM не используется: узлы двигает анимация
@export var part_role: StringName = &"door_left"
## Запасные имена узла (для старых моделей)
@export var part_aliases: PackedStringArray = []

@export_category("Движение")
## Только ANIM: имя анимации в .glb (Action из Blender). Пусто: "mech_" + id
@export var anim_name: StringName = &""
## Ось в ЛОКАЛЬНЫХ координатах родителя узла (оси Godot, не Blender). Для двери - вдоль борта
@export var axis: Vector3 = Vector3.RIGHT
## SLIDE: ход в юнитах (1 юнит = 1 см модели). ROTATE: угол в градусах
@export var travel: float = 3.0
## Секунд на полный ход
@export var duration: float = 1.2
## Состояние при создании: 0 = закрыто/покой, 1 = открыто/рабочее
@export_range(0.0, 1.0) var start_state: float = 0.0
## false: команды игнорируются, механизм стоит где стоит
@export var enabled: bool = true

@export_category("Отладка")
## true: в Output пишется привязка дорожек (какие узлы ведёт механизм, какие дорожки пропущены как неподвижные), команды и
## предупреждение «ПОЗА ИЗМЕНЕНА СНАРУЖИ», если поза неподвижного механизма ANIM изменилась (с указанием, кто в этот момент двигался)
@export var debug_log: bool = false
