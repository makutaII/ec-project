class_name GroupSelection extends RefCounted

# XX claude-switch (новый файл)
#########################
## Группа объектов, выбранных рамкой (мультиселект, шаг 1: выбрать и удалить).
#########################
## SelectTool рисует рамку и зовет select_in_rect(). Тут собираются кандидаты (все объекты рамки из CATEGORIES), а фильтр категорий
## (enabled, галки в GroupSelectionPanel) определяет, кто из них в группе (members). Членам группы вешается C_MultiSelected (фиолетовый контур).
## Фильтр помнится между рамками. Группа нигде не сохраняется.
## В рамку попадает объект, если на экране лежит его начало или любая из контрольных точек пути (начало, середина, конец каждой кривой).
## Берутся только настоящие выбираемые объекты (C_Selectable), не призраки.

signal changed

const CATEGORIES: Array[StringName] = [&"track", &"train", &"building", &"terrain"]
const LABELS := {
	&"track": "Траки",
	&"train": "Вагоны",
	&"building": "Домики",
	&"terrain": "Террейн",
}

## Включена ли категория в группу
var enabled := {&"track": true, &"train": true, &"building": true, &"terrain": true}
## Все объекты последней рамки (до фильтра)
var candidates: Array[Entity] = []
## Объекты группы: кандидаты с включенной категорией
var members: Array[Entity] = []


## Рамка. rect в экранных координатах viewport. additive = false: группа заменяется кандидатами рамки;
## additive = true (Shift): кандидаты рамки добавляются к уже выбранным
func select_in_rect(rect: Rect2, root: Node, cam: Camera3D, additive: bool = false) -> void:
	if not additive:
		_unmark_members()
		candidates.clear()
	if root != null and cam != null:
		for child in root.get_children():
			var e := child as Entity
			if e == null or e.is_queued_for_deletion() or e.has_comp(C_Ghost) or not e.has_comp(ISelectable):
				continue
			if not CATEGORIES.has(category_of(e)) or candidates.has(e):
				continue
			if _in_rect(e, rect, cam):
				candidates.append(e)
	_apply_filter()


## Добавить один объект (Shift+клик). Возвращает false, если он не из выбираемых категорий. Явный выбор перекрывает фильтр:
## если категория объекта была выключена, она включается
func add_entity(e: Entity) -> bool:
	if e == null or not is_instance_valid(e) or e.is_queued_for_deletion() or e.has_comp(C_Ghost):
		return false
	var cat := category_of(e)
	if not CATEGORIES.has(cat):
		return false
	if not candidates.has(e):
		candidates.append(e)
	enabled[cat] = true
	_apply_filter()
	return true


## Убрать один объект из группы (Shift+клик по добавленному): совсем, а не фильтром
func remove_entity(e: Entity) -> void:
	if e == null:
		return
	if is_instance_valid(e) and e.has_comp(C_MultiSelected):
		e.remove_component(C_MultiSelected)
	candidates.erase(e)
	members.erase(e)
	changed.emit()


func has_member(e: Entity) -> bool:
	return e != null and members.has(e)


func set_category_enabled(category: StringName, on: bool) -> void:
	enabled[category] = on
	_apply_filter()


## Снять группу и рамку. members чистится вместе с candidates: по нему SelectTool решает, что удалять и тащить по Del и драгу,
## и живая «группа-призрак» после снятия удаляла бы прежний выбор вместо нового (баг Del после рамки)
func clear() -> void:
	if candidates.is_empty() and members.is_empty():
		return
	_unmark_members()
	candidates.clear()
	members.clear()
	changed.emit()


## Забрать живые объекты группы (для удаления) и снять группу. Убирает их SelectTool: у него общий код с одиночным Del
func take_members() -> Array[Entity]:
	var list: Array[Entity] = []
	for e in members:
		if is_instance_valid(e) and not e.is_queued_for_deletion():
			list.append(e)
	clear()
	return list


## Сколько кандидатов в каждой категории (до фильтра)
func counts() -> Dictionary:
	var res := {}
	for cat in CATEGORIES:
		res[cat] = 0
	for e in candidates:
		if is_instance_valid(e):
			var cat := category_of(e)
			res[cat] = int(res.get(cat, 0)) + 1
	return res


static func category_of(e: Entity) -> StringName:
	var idc := e.get_comp(C_Identity) as C_Identity
	return idc.get_category() if idc else &""


# ==========================================

func _apply_filter() -> void:
	_unmark_members()
	members.clear()
	for e in candidates:
		if is_instance_valid(e) and not e.is_queued_for_deletion() and bool(enabled.get(category_of(e), true)):
			members.append(e)
			if not e.has_comp(C_MultiSelected):
				e.add_component(C_MultiSelected.new())
	changed.emit()


func _unmark_members() -> void:
	for e in members:
		if is_instance_valid(e) and e.has_comp(C_MultiSelected):
			e.remove_component(C_MultiSelected)


func _in_rect(e: Entity, rect: Rect2, cam: Camera3D) -> bool:
	for p in _probe_points(e):
		if cam.is_position_behind(p):
			continue
		if rect.has_point(cam.unproject_position(p)):
			return true
	return false


## Начало объекта и контрольные точки пути (длинный трак попадает в рамку и тогда, когда ее накрыт только его конец)
func _probe_points(e: Entity) -> Array[Vector3]:
	var pts: Array[Vector3] = [e.global_position]
	var path := e.get_comp(C_Path) as C_Path
	if path != null and path.path_node != null:
		for c in path.all_curves():
			var l := c.get_baked_length()
			for f in [0.0, 0.5, 1.0]:
				pts.append(path.path_node.to_global(c.sample_baked(l * f)))
	return pts
