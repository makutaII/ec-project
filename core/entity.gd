class_name Entity extends Node3D

######################
## (Ядро системы)
######################
## Собирает на себе все компоненты. 
## Принимает сигналы(не в буквальном смысле, а через функцию) от компонентов и тулзов через send_event и транслирует в другие компоненты

## on_added()
## Когда вызывается?:	Сразу при добавлении компонента (поштучно).
## Состояние соседей : Неизвестно (могут быть еще не добавлены).

## on_entity_ready()
## Один раз, когда Entity полностью загрузилась.  
## Полностью загружены и готовы к работе.

## ⚡Сигналы передают Script (тип компонента) для точной идентификации
signal component_added(type: Script)
signal component_removed(type: Script)

## Стиль трака из набора проекта (TSM). Пусто: у объекта нет стиля из набора (не трак) или стиль
## зафиксирован в сеттинге. Записывает TSM.resolve_for при сборке визуала, уходит в сейв
var style_id: StringName = &""
## Запрос стиля от фабрики (создание из сейва или призрак): пусто = активный стиль сессии. В сейв не идёт
var style_request: StringName = &""

# XX claude-library L4: исполнение модели (покраска и др.), ModelVariant.to_dict(). Пусто: вид модели по умолчанию.
# Целиком уходит в сейв макета (макет переносим без файлов user://), применяется в C_Visual
var variant: Dictionary = {}



func _ready():
	# Имя ноды до сборки: оно нужно компонентам (имена нод сокетов, метки механизмов)
	_assign_node_name()

	# Оповещаем все компоненты, что сущность полностью собрана
	for child in get_children():
		if child is Component:
			child.on_entity_ready()

	if not Global.debug_markers:
		return
	#DD делаем метку центра ентити для дебага
	var center = MeshInstance3D.new()
	var box_shape = BoxMesh.new()
	box_shape.size = Vector3(0.5, 0.5, 0.5)
	center.position.y = 8.0
	center.mesh = box_shape
	add_child(center)

## Имя ноды: последний сегмент ключа объекта (EntitySetting.key) заглавными и номер, например G239_01.
## Название из паспорта (оно русское, для интерфейса) в имя ноды не идет: кириллица в путях и логах неудобна.
## Номер подбирается свободный среди соседей, поэтому имена уникальны и стабильны (G239_01, G239_02, ...)
func _assign_node_name() -> void:
	var base := "ENTITY"
	var idc := get_comp(C_Identity) as C_Identity
	if idc and idc.setting:
		var key := String(idc.setting.get_key())
		base = key.get_slice(".", key.get_slice_count(".") - 1)
	base = base.validate_node_name()
	if base == "":
		base = "ENTITY"
	var parent := get_parent()
	var n := 1
	var candidate := "%s_%02d" % [base, n]
	while parent != null and parent.has_node(NodePath(candidate)) and parent.get_node(NodePath(candidate)) != self:
		n += 1
		candidate = "%s_%02d" % [base, n]
	name = candidate


## ------ BUS --------

## 💡 Ключевой способ передачи событий между компонентами. 
## Вызывается из тулзов или других компонентов
func send_event(event_name: String, data: Dictionary = {}) -> void:
	for child in get_children():
		# Если это компонент и у него есть нужная функция — вызываем её
		if child is Component and child.has_method(event_name):
			child.call(event_name, data)


## ------ КОМПОНЕНТЫ ---------

## Добавление компонента в ентити выполняется при его создании, например в PathSetting
func add_component(comp: Component):
	var type = comp.get_script()
	# Если компонент такого типа уже есть — заменяем
	if has_comp(type):
		remove_component(type)

	add_child(comp)
	comp.entity = self
	
	comp.on_added() # Отрабатывает свою функцию компонента при создании
	# ⚡ Сообщение всем компонентам через шину, которое запустит on_component_added(type) в каждом компоненте
	send_event("_on_component_added", {"type": type}) 
	# ⚡Сигнал извещает, что этот компонент создан
	component_added.emit(type)


func kill_me():
	# XX claude-table T1/T2: секцию с объектами на ней не убираем (ATTN_23 §23.12 вопрос 3). Последнюю можно (T4b)
	if has_comp(C_TableSection) and not has_comp(C_Ghost):
		var why := LYM.removal_block_reason(self)
		if why != "":
			LYM.notice.emit(why)
			return
	var power_clip = get_comp(C_PowerClip)
	if power_clip:
		PGM.unregister_clip(power_clip)
	self.queue_free()


func remove_component(type: Script): 
	var comp = get_comp(type) 
	if comp: 
		# ⚡ Предохранитель от крашей при queue_free()
		if is_queued_for_deletion():
			return
		#1. Отключаем внутри самого компонента
		comp.on_removed() 
		# 2. Мгновенно отрываем от дерева, чтобы has_comp(type) стал false прямо сейчас
		remove_child(comp)
		# 4. Освобождаем память
		comp.queue_free()
		# ⚡ Внешнее общение: дергаем классический сигнал для UI
		component_removed.emit(type) 
		# ⚡ Внутреннее общение: кричим всем компонентам через шину
		send_event("_on_component_removed", {"type": type})



## 💡 Сейв 
func save_entity() -> Dictionary:
	# Предохранитель: не сохраняем призраков или удаляемые объекты
	if has_comp(C_Ghost) or is_queued_for_deletion():
		return {}

	var identity = get_comp(C_Identity)
	if not identity or not identity.setting:
		push_error("Entity без C_Identity или настроек не может быть сохранен: ", name)
		return {}

	# Список компонентов
	var components_dict = {}
	
	# Опрашиваем все дочерние компоненты
	for child in get_children():
		if child is Component and child.has_method("save_data"):
			
			var comp_data = child.save_data() # Получили из компонента
			if not comp_data.is_empty():
				# Ключ - это тип компонента
				var comp_type = child.get_script()
				components_dict[comp_type] = comp_data # добавили в список
				
	var save_data = {
		# Данные от ентити
		"setting_path": identity.setting.resource_path,
		"transform": global_transform, 
		
		# Список данных от компонентов
		"components": components_dict 
	}
	# Стиль трака из набора проекта (ATTN_17 §17.13): ключа нет у объектов без стиля из набора
	if style_id != &"":
		save_data["style_id"] = style_id
	# XX claude-library L4: исполнение модели; ключа нет у обычных объектов, старые сейвы читаются как раньше
	if not variant.is_empty():
		save_data["variant"] = variant.duplicate(true)
	
	return save_data



## ----- Helpers--------------

## Поиск компонента (используем is_instance_of для поддержки интерфейсов/наследования)
func get_comp(type: Script) -> Component:
	for child in get_children():
		if is_instance_of(child, type):
			return child
	return null



func has_comp(type: Script) -> bool:
	return get_comp(type) != null
