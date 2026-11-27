class_name C_TerminalBlock extends C_PowerDevice

# XX claude-wire W6 (новый файл)
#####################
## Клеммник (ATTN_23 §23.9, W6)
#####################
## Соединяет контакты проводов: один вход (первая клемма слева, DEV_IN: один провод от источника или блока) и выходы
## (остальные клемм, DEV_OUT: на каждую можно подключить несколько проводов к клипам и приборам). Все выходы проводят на вход
## без переключения. Число клемм от 2 до 5 (настройка прибора, вкладка «Настройки»): лишнюю клемму можно убрать, только если на ней нет провода.
## Стоит на плите и на нижней полке, как другие блоки (C_MountDraggable).

const MIN_TERMS := 2
const MAX_TERMS := 5
## Расстояние между клеммами по оси X корпуса, u (корпус 5 u: 5 клемм помещаются)
const SPACING := 1.0

## Всего клемм (вход и выходы)
var count := 4


func title() -> String:
	return "Клеммник"


func positions() -> int:
	return 0


func state_text() -> String:
	return "клемм %d, вход слева" % count


func _term_key(i: int) -> StringName:
	return StringName("t%d" % (i + 1))


func _term_x(i: int) -> float:
	return (float(i) - float(count - 1) * 0.5) * SPACING


func _build_terminals() -> void:
	count = clampi(count, MIN_TERMS, MAX_TERMS)
	for i in count:
		_add_term(_term_key(i), PowerTerminal.Role.DEV_IN if i == 0 else PowerTerminal.Role.DEV_OUT, _term_x(i))


## Любой выход проводит на вход
func _links_of(t: PowerTerminal) -> Array:
	if t == null or t.role != PowerTerminal.Role.DEV_OUT:
		return []
	return [{"terminal": term(&"t1"), "flip": false, "via": self}]


## Меняет число клемм. Возвращает причину отказа или пусто. Убрать можно только клеммы без проводов (с конца)
func set_count(n: int) -> String:
	n = clampi(n, MIN_TERMS, MAX_TERMS)
	if n == count:
		return ""
	var old := count
	if n < old:
		for i in range(n, old):
			var t := term(_term_key(i))
			if t != null and t.has_wire():
				return "Клемма %d занята проводом: сначала отключите его" % (i + 1)
		for i in range(n, old):
			var t := term(_term_key(i))
			_terms.erase(_term_key(i))
			if t != null:
				t.collision_layer = 0
				t.remove_from_group(&"power_terminal")
				# из дерева сразу, не только queue_free: иначе _collect_meshes ещё видит сферу клеммы и C_Visual красит освобождённый узел
				if t.get_parent() != null:
					t.get_parent().remove_child(t)
				t.queue_free()
	count = n
	if n > old:
		for i in range(old, n):
			_add_term(_term_key(i), PowerTerminal.Role.DEV_OUT, _term_x(i))
	for i in count:
		var tt := term(_term_key(i))
		if tt != null:
			tt.position.x = _term_x(i)
	_collect_meshes()   # список мешей C_Visual (оверлей выбора, контур) без убранных клемм и с добавленными
	_changed()
	return ""


func save_data() -> Dictionary:
	return {"count": count}


func load_data(d: Dictionary) -> void:
	set_count(int(d.get("count", count)))
