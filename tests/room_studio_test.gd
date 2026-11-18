extends Node

## ATTN_25 RM4: Room Studio запускается отдельно и поверх игры, переключатель «Оставить активной при выходе».
## Запуск: открыть tests/room_studio_test.tscn и нажать F6. Результат в Output: во всех строках OK, в конце ИТОГ: OK.
## Проверяет: room_studio.tscn создаётся и сама строит интерфейс; без embedded и без Global.debug_mode переключателя нет;
## с обоими условиями он есть, выключен, и шлёт keep_room_changed с выбранным id (детская тоже);
## выключение шлёт пустое имя; keep_room при открытии включает переключатель и выбирает ту комнату.
## Окно студии в этом тесте не показывается и игру не трогает. Меняет только user://room_studio.cfg (последняя комната).

const SCENE := "res://core/library/room_studio/room_studio.tscn"

var _bad := 0


func check(label: String, cond: bool, detail: String = "") -> void:
	if not cond:
		_bad += 1
	print("  %s %s %s" % ["OK " if cond else "ОШИБКА", label, detail])


func _open(embedded: bool, keep: StringName = &"") -> Control:
	var packed := load(SCENE) as PackedScene
	var s := packed.instantiate() as Control
	s.set("embedded", embedded)
	s.set("keep_room", keep)
	add_child(s)
	return s


func _settle() -> void:
	for i in 4:
		await get_tree().process_frame


func _keep_button(s: Control) -> CheckButton:
	for b in s.find_children("*", "CheckButton", true, false):
		if "Оставить" in (b as CheckButton).text:
			return b as CheckButton
	return null


func _list(s: Control) -> ItemList:
	return s.find_children("*", "ItemList", true, false)[0] as ItemList


func _index_of(list: ItemList, part: String) -> int:
	for i in list.item_count:
		if part in list.get_item_text(i):
			return i
	return -1


func _free(s: Control) -> void:
	remove_child(s)
	s.queue_free()


func _ready() -> void:
	var dbg := Global.debug_mode
	check("room_studio.tscn загружается", load(SCENE) is PackedScene)

	print("== 1. Отдельно (F6): активации нет")
	Global.debug_mode = true
	var a := _open(false)
	await _settle()
	check("в списке есть комнаты", _list(a).item_count >= 4, str(_list(a).item_count))
	check("переключателя нет (embedded = false)", _keep_button(a) == null)
	_free(a)

	print("== 2. Над игрой, не админ")
	Global.debug_mode = false
	var b := _open(true)
	await _settle()
	check("переключателя нет без debug_mode", _keep_button(b) == null)
	_free(b)

	print("== 3. Над игрой, админ")
	Global.debug_mode = true
	var c := _open(true)
	await _settle()
	var cb := _keep_button(c)
	check("переключатель есть", cb != null)
	if cb != null:
		var got: Array[StringName] = []
		c.connect("keep_room_changed", func(id: StringName) -> void: got.append(id))
		var list := _list(c)
		check("по умолчанию выключен", not cb.button_pressed)
		var attic_i := _index_of(list, "Мансарда")
		var proc_i := _index_of(list, "Детская")
		check("мансарда и детская в списке", attic_i >= 0 and proc_i >= 0, "%d %d" % [attic_i, proc_i])
		list.select(attic_i)
		list.item_selected.emit(attic_i)
		check("выбор при выключенном переключателе пустое имя", got.size() == 1 and got[0] == &"", str(got))
		got.clear()
		cb.button_pressed = true
		check("включение: id выбранной комнаты", got.size() == 1 and got[0] == &"attic", str(got))
		got.clear()
		list.select(proc_i)
		list.item_selected.emit(proc_i)
		check("детскую тоже можно оставить", got.size() == 1 and got[0] == &"kid_room_10", str(got))
		got.clear()
		cb.button_pressed = false
		check("выключение: пустое имя", got.size() == 1 and got[0] == &"", str(got))
	_free(c)

	print("== 4. Переключатель восстанавливается (keep_room)")
	var d := _open(true, &"attic")
	await _settle()
	var db := _keep_button(d)
	check("переключатель включён", db != null and db.button_pressed)
	var dl := _list(d)
	var sel := dl.get_selected_items()
	check("выбрана мансарда", sel.size() == 1 and "Мансарда" in dl.get_item_text(sel[0]), str(sel))
	_free(d)

	Global.debug_mode = dbg
	print("ИТОГ: ", "OK" if _bad == 0 else "ОШИБОК %d" % _bad)
