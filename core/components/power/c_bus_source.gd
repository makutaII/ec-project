class_name C_BusSource extends C_PowerDevice

# XX claude-wire W8 (новый файл)
#####################
## Шина аксессуаров 12 В на столе (ATTN_23 §23.9, W8)
#####################
## Прибор с клеммами шины (ACCESSORY, SRC): к ним подключают провода потребителей (дом, позже фонарь и привод стрелки), напрямую или через клеммник
## в режиме шины. Сама шина одна на макет (PGM.bus: выключатель, лимит тока, защита); прибор это физическая точка, откуда она выходит.
## Правило «физическая проводка обязательна»: потребитель с клеммой запитан, только если провод дошёл до такой клеммы.
## Стоит на плите и на нижней полке, как другие блоки (C_MountDraggable).

const TERMS := 3
const SPACING := 1.4


func title() -> String:
	return "Шина 12 В"


func positions() -> int:
	return 0


func state_text() -> String:
	if PGM.bus.tripped:
		return "отключена защитой"
	return "запитана" if PGM.bus_powered() else "нет питания"


func on_added() -> void:
	super()
	if not PGM.bus_event.is_connected(_on_bus_event):
		PGM.bus_event.connect(_on_bus_event)
	if not PGM.rules_changed.is_connected(_refresh):
		PGM.rules_changed.connect(_refresh)


func _on_bus_event(_kind: String) -> void:
	_refresh()


func _build_terminals() -> void:
	term_kind = PowerTerminal.Kind.ACCESSORY
	for i in TERMS:
		_add_term(StringName("t%d" % (i + 1)), PowerTerminal.Role.SRC, (float(i) - float(TERMS - 1) * 0.5) * SPACING)


## Автопроводка шины: каждый потребитель с клеммой без провода соединяется с ближайшей клеммой этого прибора
func autowire(parent: Node) -> int:
	_lane = 0
	var made := 0
	for n in get_tree().get_nodes_in_group(&"bus_terminal"):
		var bt := n as C_BusTerminal
		if bt == null or not is_instance_valid(bt.terminal) or not bt.terminal.is_free() or not bt.terminal.wires.is_empty():
			continue
		var best: PowerTerminal = null
		var best_d := INF
		for t: PowerTerminal in _terms.values():
			var d := t.global_position.distance_to(bt.terminal.global_position)
			if d < best_d:
				best_d = d
				best = t
		if best != null and PowerTerminal.can_connect(best, bt.terminal) and _connect(parent, best, bt.terminal):
			made += 1
	return made
