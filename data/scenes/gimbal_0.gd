class_name Gimbal0 extends Node3D

########################
##  Верхний узел(Gimbal) отвечает за перемещение и вращение камеры
##  Средний узел(Elevation) отвечает за высоту
##  Нижний узел(camera) отвечает за зум (позиция z )

########################
# EXPORT PARAMS
########################
@export_group('Move')
## скорость скролла кнопками
@export_range (0.01, 1, 0.01) var wasd_speed : float = 0.1
## скорость скролла мышью
@export_range (0.0001, 0.1, 0.0001) var drag_speed : float = 0.01 
## замедление скорости скролла
@export_range (0.01, 2, 0.01)  var damp_speed : float = 0.22	
# множителя скорости
@export var speed_multiplier : int = 5
# расстояние включения множителя скорости 
@export var speed_mult_distance : int = 15 

@export_group('Zoom')
## разрешить зум к курсору
@export var zoom_to_curser: bool = true			
## отдаление
@export_range (1, 200, 0.1) var zoom_max : float = 20		
## приближение	
@export_range (0.1, 1, 0.1) var zoom_min : float = 0.5	
## замедление скорости зума	
@export_range (0, 1, 0.05)  var zoom_damp : float = 0.8
## скорость зума
@export_range (0.1, 20, 0.1) var zoom_speed : float = 10
# множитель зума при расстоянии > mult_distance
@export var zoom_multiplier : int = 5
# расстояние включения множителя зума 
@export var mult_distance : int = 15 

@export_group('Rotate')
## скорость вращения
@export_range (0.001, 0.02, 0.0001)  var  rotate_speed : float = 0.005	
## замедлентие скорости вращения
@export_range (1.0, 30.0, 0.5) var rotate_damp : float = 8
## инверсия вращения 
@export var rotate_inv: bool = false	

@export_group('Elevation')
## верхняя точка
@export_range (-4, 0, 0.01) var elevation_max : float = -2.0
## нижняя точка
@export_range (-0.3, 0.6, 0.01) var elevation_min : float = 0.02 # нижняя точка

@export_group('Helpers')
#helpers
## скролл по краю
@export var scroll_edge = false 	
## Маркер центра вкл\выкл
@export var center_visible = true
## ограничение дальности передвижения камеры(граница мира)
@export var camera_move_edge = 1000 
## Нода, к которй камеру можно зацепить
@export var target : NodePath		



########################
# PARAMS
########################
@onready var camera = $Elevation/Camera
@onready var elevation = $Elevation
var move = Vector3()	# Вектор определяет сколько будет мув
var zoom = 1.0			# Для старой версии зума. Начальный, управляет scale подвеса(гимбала)
var zoom_direction = 0	# для зума
var rotate_decelerate :Vector2 = Vector2.ZERO # замедление вращения после отпускания мыши
var camera_input :Vector2 = Vector2.ZERO	# для вращения временное смещение от мыши
# Позиция курсора
const RAY_LENGTH = 1000
const GROUND_PLANE = Plane(Vector3.UP, 0)
#var drag_mouse		# переменная из RR



########################
# OVERRIDE FUNCTIONS
########################
#_unhandled_input не работает над UI элементами, поэтому _input как земена при необходимости
func _unhandled_input(event: InputEvent) -> void: 
	if !camera.current: return
	# U10/U11: пока открыто модальное окно, колесо, МСМ и ПКМ камеру не двигают
	if UIPointer.modal_open(): return
	#rotate and elevate
	if Input.is_action_pressed("mmb"):
		#Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)		# скрыли курсор
		if event is InputEventMouseMotion:
			camera_input = event.relative

	#  Это видимо дописывал для проекта RR. Определяет drag_mouse 
	#if Input.is_action_pressed("lmb"):
		#if event is InputEvent:
			#drag_mouse = event.accumulate(event)
	#move
	if Input.is_action_pressed("rmb"):
		#Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)		# скрыли курсор
		#  Это видимо дописывал для проекта RR. Определяет drag_mouse 
		#if event is InputEvent:
			#drag_mouse = event.accumulate(event)
		if event is InputEventMouseMotion:
			var mult = 1 if camera.position.z <=speed_mult_distance else speed_multiplier
			move.x -= event.relative.x * drag_speed * mult
			move.z -= event.relative.y * drag_speed * mult
	#zoom
	if event.is_action_pressed("mouse_wheel_up"):
		zoom_direction = -1	#zoom new 
	if event.is_action_pressed("mouse_wheel_down"):
		zoom_direction = 1	#zoom new

	# курсор снова вкл
	if Input.is_action_just_released("rmb" 
									) or Input.is_action_just_released("mmb"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)



func _process(delta):
	#rotate & elavate
	#пересчет скорости вращения камеры сразу гор и верт
	rotate_decelerate = rotate_decelerate.lerp(camera_input * rotate_speed, delta * rotate_damp)
	# скорость  вращения замедляем пока не 0.001, потом 0
	rotate_decelerate = rotate_decelerate if rotate_decelerate.length() > 0.001 else Vector2.ZERO

	# перемещаем камеру
	var p = 1 if rotate_inv else -1 # инверсия если вкл
	rotate_object_local(Vector3.UP, p * rotate_decelerate.x) # вращение по горизонтали
	elevation.rotate_object_local(Vector3.RIGHT,-rotate_decelerate.y) # вращение по высоте
	#мин\макс по высоте
	elevation.rotation.x = clamp(elevation.rotation.x, elevation_max, elevation_min)
	camera_input = Vector2.ZERO # Обнуляем ввод с мыши
	
	#move camera
	move_cam(delta)
	#zoom 
	if zoom_direction != 0:
		_zoom(delta) # выполняется только если задан новый зум и был запуск из инпута
	# если нужен таргет для камеры(не проверено)
	if target:
		global_transform.origin = get_node(target).global_transform.origin



func _ready() -> void:
	%MeshCenter.visible = center_visible # Маркер центра вкл\выкл



##############################
# MOVEMENT FUNCTIONS
##############################

## новый вариант зума с зумом на курсор
## Изменение позиции Z узла camera.
func _zoom(delta: float) -> void:
	var mult = 1 if camera.position.z <=mult_distance else zoom_multiplier # Множитель зума от расстояния. 
	var new_zoom = clamp(
		camera.position.z + mult * zoom_direction * zoom_speed * delta,
		zoom_min,
		zoom_max)
	var pointing_at = _get_ground_position() # запоминаем позицию курсора на плоскости до зума
	camera.position.z = new_zoom
	# сдвиг камеры, если включен зум на курсор
	if zoom_to_curser and pointing_at != null:
		_realign_camera(pointing_at)
	
	# скорость затухания уменьшаем пока не 0.0001, потом 0
	zoom_direction *= zoom_damp
	if abs(zoom_direction) < 0.001:
		zoom_direction = 0
		
	#printt(mult,camera.position.z  )


## Клавиша движения нажата и не открыто модальное окно (U10: набор названия не двигает камеру)
func _key_down(action: StringName) -> bool:
	return not UIPointer.modal_open() and Input.is_action_pressed(action)


## Перемещение камеры 
func move_cam(_delta):
	#окно игры в фокусе
	if get_viewport().get_window().has_focus():
		#скролл по краю, то постоянно опрос позиции мыши, что не есть хорошо
		if scroll_edge and not UIPointer.modal_open():
			move_edge() 
		# вперед\назад	
		if _key_down("key_w"):
			move.z = lerp(move.z,-wasd_speed, damp_speed)
		elif _key_down("key_s"):
			move.z = lerp(move.z,wasd_speed, damp_speed)
		else: # если отпущена кнопка то замедляемся до 0
			move.z = lerp(move.z, 0.0, damp_speed)
		# влево\вправо 
		if _key_down("key_a"):
			move.x = lerp(move.x,-wasd_speed, damp_speed)
		elif _key_down("key_d"):
			move.x = lerp(move.x,wasd_speed, damp_speed)
		else: # если отпущена кнопка то замедляемся до 0
			move.x = lerp(move.x, 0.0, damp_speed)
		#move camera
		if move.length() !=0 : # камера меняет позицию  только если вектор мув не нулевой. Некоторая оптимизация и не лагает в покое
			position += move.rotated(Vector3.UP,self.rotation.y) 
			position.x = clamp(position.x,-camera_move_edge,camera_move_edge)
			position.z = clamp(position.z,-camera_move_edge,camera_move_edge)

		
		
#Сдвиг камеры по краю экрана. Тяжелая функция, т.к. выполняется постоянно
func move_edge():
		var viewport_size = get_viewport().size
		var mouse_pos = get_viewport().get_mouse_position()
		var ui_border =$"../../UI".size.y
		#get inputs
		var down_border=mouse_pos.y > ui_border and mouse_pos.y < ui_border + 20
		var up_border=mouse_pos.y < viewport_size.y - ui_border and mouse_pos.y > (viewport_size.y - ui_border - 20)
		var l_border=mouse_pos.x < viewport_size.x and mouse_pos.x > (viewport_size.x - 20)
		var r_border=mouse_pos.x > 0  and mouse_pos.x < 20
		if down_border:
			move.z = lerp(move.z,-wasd_speed, damp_speed)
		elif up_border:
			move.z = lerp(move.z,wasd_speed, damp_speed)
		else:
			move.z = lerp(move.z, 0.0, damp_speed)
		if r_border:
			move.x = lerp(move.x,-wasd_speed, damp_speed)
		elif l_border:
			move.x = lerp(move.x,wasd_speed, damp_speed)
		else:
			move.x = lerp(move.x, 0.0, damp_speed)



##############################
# HELPERS
##############################

# позиция пересечения луча и плоскости . Есть во все  скриптах.
func _get_ground_position() -> Vector3:
	var mouse_pos = get_viewport().get_mouse_position()
	var ray_from = camera.project_ray_origin(mouse_pos)
	var ray_to = ray_from + camera.project_ray_normal(mouse_pos) * RAY_LENGTH
	var cursorpos = GROUND_PLANE.intersects_ray(ray_from, ray_to) 
	if cursorpos == null:
		cursorpos = Vector3.ZERO
	return cursorpos



# сдвигаем камеру к точке на курсор
func _realign_camera(point: Vector3) -> void:
	var new_position = _get_ground_position()
	if new_position == null:
		return
	position += point - new_position	# смена позиции узла на вектор 


## Данные для сейва вызывает SaveLoad Manager
func save_global_state() -> Dictionary:
	return {
		"transform": global_transform,
		"elevation":  elevation.transform,
		"camera":  camera.transform,
	}

## Данные для лоада вызывает SaveLoad Manager
func load_global_state(data:Dictionary) -> void:
	if data.has("transform"): 
		global_transform = data.transform
	if data.has("elevation"): 
		elevation.transform = data.elevation
	if data.has("camera"): 
		camera.transform = data.camera
