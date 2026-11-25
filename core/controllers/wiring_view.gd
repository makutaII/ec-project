class_name WiringView extends Node

# XX claude-wire W3 (новый файл)
#####################
## WiringView. Вид режима «Монтаж» (ATTN_23 §23.9)
#####################
## Что показывает режим «Монтаж», пока он включён: плиту стола (LYM.plate_visible) и «пути»: как есть или схема.
## Схема прячет всё, кроме путей и проводки (поезда, здания, декор, рельеф, шпатлёвка, вода), чтобы под столом и
## над ним было видно блоки, провода и клеммы клипов. Прячет через Entity.visible: коллизии, физика и логика не меняются.
## Выход из режима возвращает всё: плита показана, скрытые объекты видны (с прежней видимостью, если её ставил кто-то другой).
## Состояние не сохраняется в сейв: игра открывается в обычном виде.
## Слой питания (кнопка «Слой питания» в боковой панели) режим не трогает: его игрок включает сам.
## Клавиша «Плита» (plate_toggle) работает только в этом режиме.

## ⚡Сигнал: сменились «пути» (кнопка в панели режима)
signal paths_changed(paths: int)

enum Paths { ALL, SCHEME }

## Категории, которые схема прячет. Дороги (track), блоки и пульты (dc_controller, dcc_controller), провода остаются
const HIDDEN_CATEGORIES: Array[StringName] = [&"train", &"building", &"decor", &"terrain"]
const META_PREV := &"_wiring_prev_visible"

var paths: int = Paths.SCHEME
var active := false
## Где лежат сущности (ToolController.entities_root)
var entities_root: Node3D

var _hidden: Array[Entity] = []


func _unhandled_input(event: InputEvent) -> void:
	if not active or UIPointer.modal_open():
		return
	if Actions.pressed(event, &"plate_toggle"):
		LYM.set_plate_visible(not LYM.plate_visible)
		get_viewport().set_input_as_handled()


## Зовёт ToolController при смене режима
func on_mode_changed(mode: StringName) -> void:
	var on := mode == &"wiring"
	if on == active:
		return
	active = on
	if on:
		_apply_paths()
	else:
		_restore()
		LYM.set_plate_visible(true)


func set_paths(value: int) -> void:
	if value == paths:
		return
	paths = value
	if active:
		_apply_paths()
	paths_changed.emit(paths)


func _apply_paths() -> void:
	_restore()
	if paths != Paths.SCHEME or entities_root == null:
		return
	for child in entities_root.get_children():
		var e := child as Entity
		if e == null or e.is_queued_for_deletion() or not e.visible:
			continue
		if HIDDEN_CATEGORIES.has(GroupSelection.category_of(e)):
			e.set_meta(META_PREV, true)
			e.visible = false
			_hidden.append(e)


func _restore() -> void:
	for e in _hidden:
		if is_instance_valid(e):
			e.visible = bool(e.get_meta(META_PREV, true))
			e.remove_meta(META_PREV)
	_hidden.clear()
