class_name C_Blockable extends IBlockable

##################################
## Библиотека действий. Она живет на объекте всегда.
##################################
## способность блочить ентити, когда включено C_Blocked

# Массив с area3d трака. Нужен для чистки коннектов при удалении компа
var areas: Array[Area3D] = []
# Количество перекрытий
var overlaps := 0



func on_added():
	var visual = entity.get_comp(C_TrackVisual)
	# area_nodes содержит все ноды с коллизиями, нам нужны только ареа
	if visual and not visual.area_nodes.is_empty():
		# Подключаемся ко ВСЕМ Area3D 
		for node in visual.area_nodes.keys():
			if node is Area3D:
				node.area_entered.connect(_on_enter)
				node.area_exited.connect(_on_exit) 
				
				areas.append(node)



## ⚡Сигнал что есть вход в area
func _on_enter(_area):

	if _should_block(_area): # Надо ли делать блок?
		overlaps += 1
		_update_state()



## Обновление стейта при входе и выходе
func _update_state():
	var is_blocked = entity.has_comp(C_Blocked)
	var should_be_blocked = overlaps > 0

	if should_be_blocked and not is_blocked:
		entity.add_component(C_Blocked.new()) # Вешаем метку

	elif not should_be_blocked and is_blocked:
		entity.remove_component(C_Blocked)    # Снимаем метку



## Надо ли делать блок
func _should_block(_area):
	var ent = find_entity_from_collider(_area) # Выдает сущность
	if not ent or ent == entity: return false # Игнорим себя
	if ent.has_comp(C_Ghost): return false    # Игнорим гостов
	# XX claude-car CS1: основания рельса и дороги не мешают друг другу (слой ghost общий, слои tracks и roads разные)
	if C_Path.network_of(ent) != C_Path.network_of(entity): return false
	return true



## Из коллайдера поднимает его Entity
func find_entity_from_collider(node: Node) -> Entity:
	var current = node
	while current:
		if current is Entity:
			return current
		current = current.get_parent()
	
	return null



## ⚡Сигнал что есть выход из area
func _on_exit(_area):
	if _should_block(_area):
		overlaps -= 1
		_update_state()



## При удалении компа чистим коннекты
func on_removed():
	for a in areas:
		if a:
			a.area_entered.disconnect(_on_enter)
			a.area_exited.disconnect(_on_exit)
	areas.clear()
		
	if entity.has_comp(C_Blocked):
		entity.remove_component(C_Blocked)

func reset_state():
	overlaps = 0
	if entity.has_comp(C_Blocked):
		entity.remove_component(C_Blocked)
