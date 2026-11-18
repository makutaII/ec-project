class_name C_CameraTarget extends Component

#######################
## 💡 Компонент клеммы питания. Точка входа напряжения.
#######################
# Данные: Ссылка на канал контроллера (contour_id), текущее подаваемое напряжение.
# Логика: При добавлении в дерево регистрирует себя в контроллере и инициирует пересчет контуров дороги.
# Визуал: добавляет сцену коробочки клеммы с индикацией текущего напряжения и id контура

var wagon_camera_scene: PackedScene = preload("res://core/camera/wagon_camera.tscn")

var camera_instance: Node3D = null
var previous_camera: Camera3D = null

# Вызывается, когда инструмент или UI посылает сигнал через entity.send_event()
func on_wagon_camera_selected(_data: Dictionary) -> void:
	if _data.selected:
		# Запоминаем текущую главную камеру, чтобы потом к ней вернуться
		var viewport = get_viewport()
		if viewport:
			previous_camera = viewport.get_camera_3d()
			
		# Инстанцируем камеру, если ее еще нет
		if not camera_instance:
			camera_instance = wagon_camera_scene.instantiate()
			# Добавляем как дочерний узел к Entity (Node3D), поэтому она будет двигаться плавно вместе с ним
			entity.add_child(camera_instance)
			# Немного приподнимаем центр вращения над рельсами
			camera_instance.position = Vector3(0, 2.0, 0.0) 
			
		# Включаем камеру вагона
		camera_instance.activate()
		
	else:
		# Выкл камера: возвращаем вид и освобождаем камеру вагона (раньше ссылка оставалась)
		if is_instance_valid(previous_camera):
			previous_camera.make_current()
		if is_instance_valid(camera_instance):
			camera_instance.queue_free()
		camera_instance = null


# U13 (D13): секция вкладки Visual в InfoPanel: переключатель камеры вагона. Источник истины это
# camera_instance, поэтому переключатель верен и когда камеру включил Observe (режим Follow)
func get_info_sections() -> Array[InfoSection]:
	return [InfoSection.make("Камера", [
		InfoSection.toggle("Камера вагона",
			func() -> bool: return camera_instance != null,
			func(on: bool) -> void: entity.send_event("on_wagon_camera_selected", {"selected": on})),
	])]


# Вызывается при снятии выделения (например, send_event("on_wagon_deselected"))
func on_wagon_deselected(_data: Dictionary) -> void:
	pass
		
		
		
# Entity запускает это при создании компонента
func on_added():
	name = 'C_Camera_Target'


	

#------SAVE\LOAD----

# Сейв данных по запросу ентити
#func save_data() -> Dictionary:
	#return {
		## не исп
		#'comp_path':get_script().resource_path, #  "res://core/components/c_power_clip.gd"
		## не исп, для наглядности в сейве
		#'comp_name':get_script().resource_path.get_file().get_basename(), # "c_power_clip"
		#"contour_id": contour_id,
		#"voltage": voltage,
#
	#}
#
#
#
#func load_data(_data: Dictionary) -> void:
	#if _data.has("contour_id"):
		#contour_id = _data.contour_id
	#if _data.has("voltage"):
		#voltage = _data.voltage
