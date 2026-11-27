class_name AutoWire extends RefCounted

# XX claude-wire W7 (новый файл)
## Трасса автопроводки между двумя клеммами (ATTN_23 §23.9, W7). Использует C_PowerSource.autowire и C_PowerDevice.autowire.
## Есть нижняя полка: провод уходит через ввод в плите, идёт по полке в обход ножек и поднимается у второй клеммы (WireRouter).
## Полки нет или маршрут не нашёлся: провод идёт по поверхностям напрямую между точками под клеммами, а не дугой по воздуху.
## lane: номер провода в серии автопроводки, соседние идут со сдвигом.


static func points(a: PowerTerminal, b: PowerTerminal, lane := 0) -> PackedVector3Array:
	var da: Variant = WireSurface.drop(a)
	var db: Variant = WireSurface.drop(b)
	var pa: Vector3 = da if da != null else a.global_position
	var pb: Vector3 = db if db != null else b.global_position
	if not LYM.shelf_polygons().is_empty():
		var world := a.get_world_3d()
		var ctx := {
			"walkable": LYM.shelf_walkable(),
			"keepouts": LYM.leg_keepouts(),
			"shelf_y": LYM.shelf_top() + Global.settings.wire_lift,
			"surface_y": func(x: float, z: float) -> float: return WireSurface.height_at(world, x, z),
			"hole_reason": func(p: Vector3) -> String: return Mount.hole_reason(p),
			"lane": lane,
		}
		var routed := WireRouter.route(pa, pb, ctx)
		if not routed.is_empty():
			return routed
	var res := PackedVector3Array()
	if da != null:
		res.append(da)
	if db != null:
		res.append(db)
	return res
