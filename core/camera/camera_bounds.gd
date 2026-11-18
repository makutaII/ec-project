class_name CameraBounds extends Node

########################
## Подаёт Gimbal границы комнаты (RoomConfig.bounds).
## Сами ограничения живут внутри Gimbal (на целевом состоянии), здесь только связка:
## Границы заданы всегда, включает их Gimbal (по умолчанию свободная камера). Комнату сменили: границы читаются заново.
########################

var gimbal: Gimbal


func _ready() -> void:
	gimbal = get_node_or_null("/root/GameRoot/Gimbal") as Gimbal
	if gimbal == null:
		return
	# RoomRoot встаёт в группу в своём _ready, ждём кадр
	await get_tree().process_frame
	var room := get_tree().get_first_node_in_group(&"room_root") as RoomBuilder
	if room == null:
		# Нет комнаты (fast_debug): границ нет, камера свободная, можно уехать далеко и заглянуть снизу
		gimbal.set_bounds_enabled(false)
		gimbal.set_free_camera(true)
		return
	gimbal.set_bounds(room.get_bounds(), false)   # границы заданы, но выключены
	gimbal.set_free_camera(true)                  # свободная камера по умолчанию
	# Другая комната: новые границы (включены, если комната показана)
	room.room_changed.connect(func(_id): gimbal.set_bounds(room.get_bounds(), room.visuals == null or room.visuals.visible))
	# XX claude-table T3: высота стола меняет потолок, границы пересчитываются, включённость прежняя
	room.room_layout_applied.connect(func(): gimbal.update_bounds(room.get_bounds()))
