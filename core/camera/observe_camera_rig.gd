class_name ObserveCameraRig extends Node

########################
## Камеры и фоторежим Observe (TDD §14.5, S9)
########################
## Режимы камеры: NONE (обычный Gimbal), FOLLOW (камера вагона C_CameraTarget), POV (камера на вагоне
## по ходу), ORBIT (автокамера вокруг стола). Закладки 1-5 запоминают позу Gimbal. Фоторежим: скрыть UI и снимок.
## Работает только пока активен режим Observe. Управляется карточками категорий Camera и Photo
## (ObserveController.observe_action) и клавишами:
##   1-5 перейти к закладке (пустая: сохранить), Ctrl+1-5 или Shift+карточка: перезаписать закладку,
##   H скрыть/показать UI, P снимок, Esc выйти из Follow/POV/Orbit или вернуть UI.
## Вагон выбирает ObserveTool кликом (pick_target).

enum Mode { NONE, FOLLOW, POV, ORBIT }

const BOOKMARK_COUNT := 5
const SCREENSHOT_DIR := "user://screenshots/"

@export var orbit_speed_deg := 8.0
@export var orbit_center := Vector3(0.0, 8.0, 0.0)
## Где сидит POV-камера в координатах вагона. Направление взгляда: -Z вагона (переключатель POV ↔ разворачивает)
@export var pov_offset := Vector3(0.0, 3.0, 0.0)
@export var pov_fov := 70.0

## ⚡Режим камеры сменился
signal mode_changed(mode: int)

var mode: Mode = Mode.NONE
var target: Entity

var _active := false
var _flip := false
var _ui_hidden := false
var _gimbal: Gimbal
var _gimbal_cam: Camera3D
var _pov_cam: Camera3D
var _orbit_cam: Camera3D
var _orbit_angle := 0.0
var _orbit_radius := 150.0
var _orbit_height := 80.0
var _oc: Node
var _bookmarks: Array = []


func _ready() -> void:
	add_to_group(&"observe_camera_rig")
	_gimbal = get_node_or_null("/root/GameRoot/Gimbal") as Gimbal
	if _gimbal:
		_gimbal_cam = _gimbal.get_node_or_null("Elevation/Camera")
	else:
		push_warning("ObserveCameraRig: Gimbal не найден (/root/GameRoot/Gimbal)")
	_load_bookmarks()
	set_process(false)
	await get_tree().process_frame
	_oc = get_tree().get_first_node_in_group(&"observe_controller")
	if _oc:
		_oc.observe_action.connect(_on_observe_action)
		_oc.observe_entered.connect(_on_enter)
		_oc.observe_exited.connect(_on_exit)
	else:
		push_warning("ObserveCameraRig: ObserveController не найден, карточки камер не работают")


func _on_enter() -> void:
	_active = true
	_sync_cards()


func _on_exit() -> void:
	_active = false
	set_mode(Mode.NONE)
	set_ui_hidden(false)
	target = null


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var i := _bookmark_from_event(event)
		if i >= 0:
			if event.ctrl_pressed or _bookmarks[i] == null:
				save_bookmark(i)
			else:
				go_bookmark(i)
		elif Actions.pressed(event, &"photo_hide_ui"):
			set_ui_hidden(not _ui_hidden)
		elif Actions.pressed(event, &"photo_snap"):
			take_photo()
		elif Actions.pressed(event, &"observe_cancel"):
			if _ui_hidden:
				set_ui_hidden(false)
			elif mode != Mode.NONE:
				set_mode(Mode.NONE)


# ==========================================
# ЦЕЛЬ И РЕЖИМЫ
# ==========================================

## Номер закладки (с нуля) по клавише bookmark_N или -1. Ctrl и Shift не мешают: Ctrl+цифра сохраняет закладку
func _bookmark_from_event(event: InputEvent) -> int:
	for i in BOOKMARK_COUNT:
		if event.is_action(StringName("bookmark_%d" % (i + 1))):
			return i
	return -1


## Клик ObserveTool по вагону: включаем Follow на нем (в POV переносим камеру на новый вагон)
func pick_target(e: Entity) -> void:
	if e == null:
		return
	if mode == Mode.POV:
		_leave_mode(Mode.POV)
		target = e
		_enter_mode(Mode.POV)
		_sync_cards()
		return
	if mode == Mode.FOLLOW and e == target:
		return
	set_mode(Mode.NONE)
	target = e
	set_mode(Mode.FOLLOW)
	_sync_cards()


func set_mode(m: Mode) -> void:
	if m == mode:
		return
	_leave_mode(mode)
	mode = m
	_enter_mode(m)
	mode_changed.emit(mode)
	Hints.set_extra([&"", &"follow", &"pov", &"orbit"][mode])


func _enter_mode(m: Mode) -> void:
	match m:
		Mode.FOLLOW:
			if is_instance_valid(target) and target.has_comp(C_CameraTarget):
				target.send_event("on_wagon_camera_selected", {"selected": true})
			else:
				mode = Mode.NONE
		Mode.POV:
			if is_instance_valid(target):
				_pov_cam = Camera3D.new()
				_pov_cam.name = "ObservePovCamera"
				target.add_child(_pov_cam)
				_pov_cam.position = pov_offset
				_pov_cam.rotation = Vector3(0.0, PI if _flip else 0.0, 0.0)
				_pov_cam.fov = pov_fov
				_pov_cam.near = 0.1
				_pov_cam.far = 1000.0
				_pov_cam.make_current()
			else:
				mode = Mode.NONE
		Mode.ORBIT:
			if _gimbal_cam:
				var p := _gimbal_cam.global_position
				var d := Vector2(p.x - orbit_center.x, p.z - orbit_center.z)
				_orbit_angle = atan2(d.x, d.y)   # стартуем с текущего положения, без скачка
				_orbit_radius = clampf(d.length(), 60.0, 200.0)
				_orbit_height = clampf(p.y, 30.0, 170.0)
				_orbit_cam = Camera3D.new()
				_orbit_cam.name = "ObserveOrbitCamera"
				add_child(_orbit_cam)
				_orbit_cam.near = 0.1
				_orbit_cam.far = 1000.0
				_orbit_cam.make_current()
				set_process(true)
				_process(0.0)
			else:
				mode = Mode.NONE


func _leave_mode(m: Mode) -> void:
	match m:
		Mode.FOLLOW:
			if is_instance_valid(target):
				target.send_event("on_wagon_camera_selected", {"selected": false})
		Mode.POV:
			if is_instance_valid(_pov_cam):
				_pov_cam.queue_free()
			_pov_cam = null
		Mode.ORBIT:
			set_process(false)
			if is_instance_valid(_orbit_cam):
				_orbit_cam.queue_free()
			_orbit_cam = null
	if m != Mode.NONE and is_instance_valid(_gimbal_cam):
		_gimbal_cam.make_current()   # вид всегда возвращается на Gimbal


func _process(delta: float) -> void:
	if mode != Mode.ORBIT or not is_instance_valid(_orbit_cam):
		return
	_orbit_angle += deg_to_rad(orbit_speed_deg) * delta
	var pos := Vector3(orbit_center.x + sin(_orbit_angle) * _orbit_radius, _orbit_height,
			orbit_center.z + cos(_orbit_angle) * _orbit_radius)
	_orbit_cam.global_position = _clamp_to_room(pos)
	_orbit_cam.look_at(orbit_center, Vector3.UP)


func _clamp_to_room(p: Vector3) -> Vector3:
	var b := AABB(Vector3(-230.0, 3.0, -180.0), Vector3(460.0, 190.0, 360.0))
	var room := get_tree().get_first_node_in_group(&"room_root") as RoomBuilder
	if room:
		b = room.get_bounds()
	return p.clamp(b.position + Vector3(8.0, 0.0, 8.0), b.end - Vector3(8.0, 8.0, 8.0))


# ==========================================
# ЗАКЛАДКИ
# ==========================================

func save_bookmark(i: int) -> void:
	if _gimbal == null or mode != Mode.NONE:
		return   # сохраняем только вид Gimbal
	_bookmarks[i] = _gimbal.save_global_state()
	_save_bookmarks()
	print("[Observe] закладка %d сохранена" % (i + 1))


func go_bookmark(i: int) -> void:
	var bm = _bookmarks[i]
	set_mode(Mode.NONE)
	_sync_cards()
	if _gimbal == null or not _valid_bookmark(bm):
		return
	# Gimbal сам плавно едет к целевому виду (snap = false), отдельный твин не нужен
	_gimbal.set_view(bm.pivot, bm.yaw, bm.pitch, bm.dist)


## Формат Gimbal.get_view(): pivot, yaw, pitch, dist. Старый формат (transform, elevation, camera) не поддерживаем
func _valid_bookmark(bm) -> bool:
	return bm is Dictionary and bm.has("pivot") and bm.has("yaw") and bm.has("pitch") and bm.has("dist")


func _load_bookmarks() -> void:
	var stored = Settings.get_value("camera", "bookmarks", [])
	_bookmarks.clear()
	for i in BOOKMARK_COUNT:
		var bm = stored[i] if stored is Array and i < stored.size() else null
		_bookmarks.append(bm if _valid_bookmark(bm) else null)


func _save_bookmarks() -> void:
	Settings.set_value("camera", "bookmarks", _bookmarks.duplicate(true))


# ==========================================
# ФОТОРЕЖИМ
# ==========================================

func set_ui_hidden(on: bool) -> void:
	_ui_hidden = on
	Hints.set_context(&"photo", on)
	var ui := get_node_or_null("/root/GameRoot/UI")
	if ui and ui.has_method("set_hud_visible"):
		ui.set_hud_visible(not on)   # только HUD: окна и тосты остаются
	elif ui and "visible" in ui:
		ui.visible = not on
	_sync_cards()


## Снимок без UI на качестве High. Файл: user://screenshots/
func take_photo() -> void:
	var ui_was_hidden := _ui_hidden
	Hints.suspend(true)   # подсказки не должны попасть в кадр
	set_ui_hidden(true)
	var prev_quality: StringName = GFX.state.quality
	GFX.apply_quality(&"high", 0.0, false)   # временно, в настройки не пишется
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(SCREENSHOT_DIR)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := SCREENSHOT_DIR + "ec_" + stamp + ".png"
	var err := img.save_png(path)
	if err == OK:
		print("[Observe] снимок сохранён: ", ProjectSettings.globalize_path(path))
	else:
		push_error("Observe: не удалось сохранить снимок (код %d)" % err)
	GFX.apply_quality(prev_quality, 0.0, false)
	Hints.suspend(false)
	if not ui_was_hidden:
		set_ui_hidden(false)


# ==========================================
# КАРТОЧКИ
# ==========================================

## ⚡Сигнал из ObserveController
func _on_observe_action(_cat: StringName, _id: StringName, _pressed: bool) -> void:
	if _cat == &'camera':
		var s := String(_id)
		if s.begins_with("bookmark_"):
			var i := int(s.get_slice("_", 1)) - 1
			if i < 0 or i >= BOOKMARK_COUNT:
				return
			if Actions.shift() or _bookmarks[i] == null:
				save_bookmark(i)
			else:
				go_bookmark(i)
			return
		match _id:
			&'follow':
				_toggle_mode(Mode.FOLLOW, _pressed)
			&'pov':
				_toggle_mode(Mode.POV, _pressed)
			&'orbit':
				_toggle_mode(Mode.ORBIT, _pressed)
			&'pov_flip':
				_flip = _pressed
				if mode == Mode.POV:
					_leave_mode(Mode.POV)
					_enter_mode(Mode.POV)
	elif _cat == &'photo':
		match _id:
			&'hide_ui':
				set_ui_hidden(_pressed)
			&'snapshot':
				take_photo()


func _toggle_mode(m: Mode, on: bool) -> void:
	if on and m != Mode.ORBIT and not is_instance_valid(target):
		print("[Observe] сначала кликните по вагону")
	set_mode(m if on else Mode.NONE)
	_sync_cards()   # если режим не включился (нет цели), карточка возвращается в исходное состояние


func _sync_cards() -> void:
	if not is_instance_valid(_oc):
		return
	_oc.set_toggle_state(&"follow", mode == Mode.FOLLOW)
	_oc.set_toggle_state(&"pov", mode == Mode.POV)
	_oc.set_toggle_state(&"orbit", mode == Mode.ORBIT)
	_oc.set_toggle_state(&"pov_flip", _flip)
	_oc.set_toggle_state(&"hide_ui", _ui_hidden)
