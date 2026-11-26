extends Node
# class_name не задаём: это синглтон CSM (autoload), как TGM, LYM и PGM
###########################
## CSM. Менеджер системы машин (autoload), ATTN_28 CS2
###########################
## Хранит машины (C_RoadVehicle регистрируется сам при готовности сущности) и гоняет решения с частотой TICK_HZ.
## Положение машина интегрирует сама каждый физический кадр (C_RoadVehicle._physics_process), а решения (остановиться на конце
## дороги, поехать снова, потерять полосу) считаются здесь реже: 20 Гц, как в Wunderland (ATTN_28 §28.6).
## CS3 добавит сюда проверку наезда машин на одной полосе, CS4 управляющие элементы.

## Частота решений, Гц
const TICK_HZ := 20.0
const TICK := 1.0 / TICK_HZ

## ⚡ Тик решений. dt это прошедшее с прошлого тика время, с
signal ticked(dt: float)

var _vehicles: Array[C_RoadVehicle] = []
var _acc := 0.0


func register(v: C_RoadVehicle) -> void:
	if v != null and not _vehicles.has(v):
		_vehicles.append(v)


func unregister(v: C_RoadVehicle) -> void:
	_vehicles.erase(v)


## Живые машины (без удаляемых)
func get_vehicles() -> Array[C_RoadVehicle]:
	var res: Array[C_RoadVehicle] = []
	for v in _vehicles:
		if is_instance_valid(v) and not v.is_queued_for_deletion():
			res.append(v)
	return res


func count() -> int:
	return get_vehicles().size()


func _physics_process(delta: float) -> void:
	_acc += delta
	if _acc < TICK:
		return
	var dt := _acc
	_acc = 0.0
	var alive: Array[C_RoadVehicle] = []
	for v in _vehicles:
		if is_instance_valid(v):
			alive.append(v)
			v.decide(dt)
	_vehicles = alive
	ticked.emit(dt)
