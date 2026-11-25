class_name C_RoadBed extends ICapability

###########################
## Сообщает рельефу, что дорога встала, сдвинулась или убрана (ATTN_28 Р10, CS1b)
###########################
## Листы пенопласта и поле пересчитывают ложе (канаву, выемку, насыпь) по событию TGM.terrain_changed.
## У рельсовых траков это событие шлёт C_TrackSupport (_notify_terrain), а у дороги этого компонента пока нет:
## без него ложе под дорогой пересчитывалось, только когда рядом двигали жд трак.
## Здесь только уведомление, опор нет. Когда дорога получит опоры эстакады (CS1c, TrackSupportSettings),
## C_TrackSupport шлёт то же событие сам, и этот компонент из сегментов убирается.
## Те же причины, что у C_TrackSupport: создание (отложенно), конец драга, удаление. Призрак и дорога в драге молчат.


func on_entity_ready() -> void:
	call_deferred("_notify_terrain")


func on_drag_ended(_d: Dictionary) -> void:
	_notify_terrain()


func _exit_tree() -> void:
	_notify_terrain()


## Область: контур ложа от низа основания до верха полотна. Удаляемая дорога тоже сообщает (TGM.get_tracks её уже не отдаст)
func _notify_terrain() -> void:
	if not is_instance_valid(TGM) or entity == null or not entity.is_inside_tree():
		return
	if entity.has_comp(C_Ghost) or entity.has_comp(C_Drag):
		return
	var path := get_comp(C_Path) as C_Path
	if path == null:
		return
	var s := path.ballast_samples()
	if s.size() < 2:
		return
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var y_lo := INF
	var y_hi := -INF
	for d in s:
		var l: Vector2 = d["l"]
		var r: Vector2 = d["r"]
		lo = lo.min(l).min(r)
		hi = hi.max(l).max(r)
		var y: float = d["y"]
		y_lo = minf(y_lo, y)
		y_hi = maxf(y_hi, y)
	var top: float = y_hi + path.head_height()
	TGM.notify_changed(AABB(Vector3(lo.x, y_lo, lo.y), Vector3(hi.x - lo.x, top - y_lo, hi.y - lo.y)))
