class_name C_TrainVisual extends C_Visual

###################################
## Логика. Обработка файла сцены вагона
###################################

## За перемещение физического тела отвечает кинематикс, у него есть ссылка на него.
## Строит вагон согласно данным Identity - WagonConfig

var rb: RigidBody3D # Ссылка на наш физический кузов

const WHEEL_SHADER := preload("res://core/visual/materials/shader_wheel01_material.tres")

# Массив нод с коллизиями
var collision_nodes: Array[CollisionObject3D] 

## Паспортные значения задает TrainVisualSettings до add_component, компонент паспорт не читает
var bogie_configs: Array[BogieConfig] = []
## Смещение меша от пола (меньше диаметра колеса на ~0.2)
var offset_mesh_y := 1.061

var bogie_nodes: Array[Node3D] = []

var wheel_nodes: Array[Dictionary] = [] # все колеса {'wheel_node', 'radius', 'bogie': номер тележки, 'sign': +1/-1 по Z, 'axle': номер оси в узле}
## Коллизии тележек по номеру тележки в паспорте (нужны для правки раскладки в DebugPanel)
var bogie_collisions: Array[CollisionShape3D] = []


# XX claude
func _on_instance_ready() -> void:
	rb = instance as RigidBody3D
	# Вагон видит комнату (пол, стены) независимо от того, что стоит в маске сцены
	rb.collision_mask |= Global.active_layers(['room', 'supports'])   # XX claude-terra 13.1.5: сход на эстакаде, и вагон из сейва
	# Слой коллизии задаёт код, а не сцена: у сцены-обёртки из .glb слой по умолчанию 1 (земля), и луч курсора отбрасывал боковые
	# грани вагона как «бок земли» (ховер был только по крыше, пока вагон не выбрали и не сняли выбор). Дальше слой переключает выбор
	on_select_layer({"enabled": false})
	_collect_collision_nodes()
	_build_bogies()          # твой нынешний цикл по bogie_configs
	
##TODO  Если захочешь подсвечивать и их, пересобирай mesh_nodes после _build_bogies(), но тогда придётся исключить WheelPairMesh из _set_overlay, иначе выделение затрёт overlay колёс. Оставь комментарий в коде, чтобы потом не споткнуться.	

## on_added() НЕ переопределяем — базовый C_Visual.on_added()
## уже создаёт instance, собирает меши и вызывает _on_instance_ready().


# XX claude функция вместо скрипта в on_added()
func _build_bogies():
	# достраиваем боги (bogie_configs и offset_mesh_y пришли из паспорта через TrainVisualSettings)
	for bogie_index in bogie_configs.size():
		var bogie: BogieConfig = bogie_configs[bogie_index]
		# 1. Создаем сцену боги
		var b_scene = bogie.scene.instantiate() 
		## моя‼️Замена b_offset на b_offset_z
		b_scene.position.y = bogie.wheel_pair_position.y  # У боги своя независимая позиция в конфиге
		b_scene.position.z = bogie.b_offset_z  # У боги своя независимая позиция в конфиге
		
		# 2. Колёсные пары: одна ось, две (±z) или любое число (BogieConfig.axle_offsets)
		var axles := bogie.axle_list()
		for axle_i in axles.size():
			var wp_scene = bogie.wheel_pair_scene.instantiate() # Создаем сцену колеса
			b_scene.add_child(wp_scene)
			wp_scene.position.z = axles[axle_i] # Смещение вперед\назад
			wheel_nodes.append({'wheel_node': wp_scene, 'radius': bogie.wheel_pair_position.y, 'bogie': bogie_index,
					'sign': 1.0 if axle_i == 0 else -1.0, 'axle': axle_i})

		# 3. Перестраиваем коллизию боги c колесами к вагону
		var bg_collision = CollisionShape3D.new()
		var sh = BoxShape3D.new()
		# установка размеров коллизии боги
		sh.size = Vector3( 2.02, 
						bogie.wheel_pair_position.y * 2.0, # Диаметр колеса без реборды
						BogieMath.collision_length(bogie.half_base(), bogie.wheel_pair_position.y) # расстояние между крайними осями + радиусы обоих колес
						)
		bg_collision.shape = sh
		bg_collision.position = b_scene.position # коллизию в точку боги
		instance.add_child(bg_collision)
		bogie_collisions.append(bg_collision)
		bg_collision.name = 'BogieCollisionShape3D_01'

		instance.add_child(b_scene) # боги и колеса
		b_scene.name = 'Bogie_01'

		# Ноду добавляем в массив. Дальше им занимается C_Bogie 
		bogie_nodes.append(b_scene)
		
	#INFO  Шейдер на колеса
	for wheel in wheel_nodes:
			var _mesh = wheel.wheel_node.get_node('WheelPairMesh')
			# Свой экземпляр материала на каждое колесо: C_Bogie пишет в него slip_blend,
			# общий ресурс на все колёса всех вагонов даёт чужое значение и мерцание цвета
			_mesh.set_material_overlay(WHEEL_SHADER.duplicate())
			
	#поднимаем кузов
	# Коллизия кузова в сцене уже подогнана под меш (обнимает его). Поэтому не пересчитываем её высоту
	# по размеру коробки, а сдвигаем на столько же, на сколько поднимаем меш: взаимная посадка остаётся как в редакторе.
	# Раньше высота считалась от позиции меша ДО подъема, и коллизия оставалась у пола, а меш уезжал вверх.
	var wagon_collision = instance.get_node('WagonCollisionShape3D')
	var lift_y: float = offset_mesh_y - mesh_nodes[0].position.y
	mesh_nodes[0].position.y = offset_mesh_y # из вагон-конфига
	wagon_collision.position.y += lift_y



# XX claude замена
func on_select_layer(_data) -> void:
	if not rb: return
	if _data.enabled:
		rb.collision_layer = Global.active_layers(['ghost'])
		# XX claude-terra 13.1.7: выбранный вагон лежит на слое ghost, и пинок вагона (он выбран) шел мимо опор
		rb.collision_mask = Global.active_layers(['ground','tracks','trains','room','supports'])
	else:
		rb.collision_layer = Global.active_layers(['trains'])
		rb.collision_mask = Global.active_layers(['ground','tracks','trains','ghost','room','supports'])   # XX claude-terra 13.1.5: опоры эстакады
		


## -----Сбор нод с коллизиями (Area3D, StaticBody3D, RigidBody3D)-------

func _collect_collision_nodes():
	collision_nodes = []
	_find_collisions(instance)


## Заполняем массив коллизий
func _find_collisions(node): 
	if node is CollisionObject3D: 
		collision_nodes.append(node)

	for child in node.get_children(): 
		_find_collisions(child)
		


## --- Раскладка для DebugPanel (U14, вкладка Layout) ---
## Меняют положение узлов уже собранного вагона. Паспорт не трогают: значения берутся из копии конфига вагона.

## Высота меша кузова над началом вагона (WagonConfig.offset_mesh_y). null, если меша нет
func get_mesh_offset_y() -> Variant:
	if mesh_nodes.is_empty():
		return null
	return mesh_nodes[0].position.y


## Двигает меш кузова. Коллизия кузова не двигается (она собрана один раз при создании вагона)
func set_mesh_offset_y(y: float) -> void:
	if not mesh_nodes.is_empty():
		mesh_nodes[0].position.y = y


## Применяет b_offset_z и wheel_pair_position тележки с номером index (как в паспорте) к ее узлам:
## тележка, колеса, радиус для вращения, коллизия. Одна ось или две решается при сборке, здесь не меняется
func apply_bogie_layout(index: int, cfg: BogieConfig) -> void:
	if index < 0 or index >= bogie_nodes.size():
		return
	var node := bogie_nodes[index]
	node.position.y = cfg.wheel_pair_position.y
	node.position.z = cfg.b_offset_z
	var axles := cfg.axle_list()
	for w in wheel_nodes:
		if w.bogie != index:
			continue
		w.radius = cfg.wheel_pair_position.y
		var axle_i: int = w.get('axle', 0)
		(w.wheel_node as Node3D).position.z = axles[axle_i] if axle_i < axles.size() else cfg.wheel_pair_position.z * w.sign
	if index < bogie_collisions.size():
		var col := bogie_collisions[index]
		col.position = node.position
		(col.shape as BoxShape3D).size = Vector3(2.02, cfg.wheel_pair_position.y * 2.0,
				BogieMath.collision_length(cfg.half_base(), cfg.wheel_pair_position.y))
