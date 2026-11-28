class_name C_BusTerminal extends Component

# XX claude-wire W8 (новый файл)
#####################
## Клемма шины аксессуаров на потребителе (ATTN_23 §23.9, W8; ATTN_10 §10.15)
#####################
## Ставится в паспорт объекта, который питается от шины 12 В (дом с лампами `power_source = BUS`, позже привод стрелки и фонарь):
## создаёт клемму ACCESSORY (SINK, ключ "bus") на объекте, куда подключают провод от шины (C_BusSource, клеммник в режиме шины).
## Правило «физическая проводка обязательна» (PGM.wiring_required): объект запитан, только если к клемме подключён провод и путь
## по проводам и клеммникам дошёл до клеммы шины (DeviceGraph.reach). Без правила или без этого компонента шина питает объекты виртуально,
## как раньше. Решение читают потребители через PGM.bus_powered_for(entity).

## Положение клеммы на объекте (локальные координаты сущности)
var offset := Vector3(0.0, 1.0, 0.0)

var terminal: PowerTerminal
## К клемме подключён провод; путь дошёл до клеммы шины (считает PGM._solve_wiring)
var wired := false
var reachable := false


func on_added() -> void:
	name = 'C_BusTerminal'
	terminal = PowerTerminal.create(entity, entity, PowerTerminal.Kind.ACCESSORY, PowerTerminal.Role.SINK, &"bus", offset)
	if entity.has_comp(C_Ghost):
		_disable()
	else:
		add_to_group(&"bus_terminal")


## Призрак стройки не потребитель: клемма выключена
func on_component_added(type: Script) -> void:
	if type == C_Ghost:
		_disable()


## Призрак стал настоящим объектом: клемма включается
func on_component_removed(type: Script) -> void:
	if type == C_Ghost and is_instance_valid(terminal):
		terminal.collision_layer = Global.active_layers(["power"])
		terminal.add_to_group(&"power_terminal")
		add_to_group(&"bus_terminal")
		PGM.request_recalculate()


func _disable() -> void:
	remove_from_group(&"bus_terminal")
	if is_instance_valid(terminal):
		terminal.collision_layer = 0
		terminal.remove_from_group(&"power_terminal")


## Ответ DeviceGraph.reach для этой клеммы
func apply_bus(res: Dictionary) -> void:
	wired = bool(res.get("wired", false))
	reachable = bool(res.get("reachable", false))


## Питание дошло до объекта по проводам
func is_fed() -> bool:
	return wired and reachable
