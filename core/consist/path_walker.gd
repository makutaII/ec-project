class_name PathWalker extends RefCounted

###########################
## PathWalker. Ходьба по пути от точки на сплайне на заданное расстояние (XX claude-car CS2, ATTN_28)
###########################
## База для RailWalker (рельсы, слой tracks) и ходьбы машин по дороге (слой roads). Слой это параметр advance (по умолчанию tracks),
## рельсовое поведение не меняется.
## Нужна, чтобы расставить части состава вдоль пути, в том числе через стыки траков.
## Состояние: {"track": Entity, "route": int, "dist": float, "dir": float}
##   dist - положение на сплайне (как C_Bogie.track_distance), dir = +1 или -1: в какую сторону по сплайну
##   идёт «ходьба». advance() всегда идёт ВПЕРЁД по dir, назад - через reversed().
## Переход на соседний трак как у C_Bogie._assist_check_transition: точка за краем (с запасом на стык)
## ищется лучом по слою tracks, дальше проекция на новую кривую.

const PROBE_AHEAD := 0.1   # м, запас вперёд, чтобы перепрыгнуть зазор стыка
const RAY_UP := 0.6        # м, старт луча над поверхностью трака
const RAY_DOWN := 1.0      # м, длина луча вниз


## Состояние от точки посадки. world_dir - мировое направление, в котором будем идти
static func from_snap(track: Entity, route: int, dist: float, world_dir: Vector3) -> Dictionary:
	var pc := _path(track)
	if pc == null:
		return {}
	var d := 1.0 if _tangent(pc, route, dist).dot(world_dir) >= 0.0 else -1.0
	return {"track": track, "route": route, "dist": dist, "dir": d}


## Радиус кривой в этой точке, ю (INF у прямой). XX claude-car CS3: от него считается скорость машины в повороте
static func radius_at(s: Dictionary) -> float:
	var pc := _path(s.track)
	return pc.radius_at(s.dist) if pc != null else INF


## Сколько осталось идти до края маршрута по направлению ходьбы. XX claude-car CS3: до конца дороги машина тормозит заранее
static func dist_to_end(s: Dictionary) -> float:
	var pc := _path(s.track)
	if pc == null:
		return 0.0
	var length := pc.curve_of(s.route).get_baked_length()
	return (length - float(s.dist)) if float(s.dir) > 0.0 else float(s.dist)


## Мировое направление ходьбы в этой точке
static func heading(s: Dictionary) -> Vector3:
	var pc := _path(s.track)
	return _tangent(pc, s.route, s.dist) * float(s.dir)


## Центр кузова над этой точкой (как у C_TrainDraggable: точка сплайна + высота головки)
static func body_point(s: Dictionary) -> Vector3:
	var pc := _path(s.track)
	return _point(pc, s.route, s.dist) + Vector3(0.0, pc.head_height(), 0.0)


## То же состояние, но ходьба в обратную сторону
static func reversed(s: Dictionary) -> Dictionary:
	var r := s.duplicate()
	r.dir = -float(s.dir)
	return r


## Идёт вперёд на d метров (d >= 0). Пусто: путь кончился или дальше нет трака.
## layer: слой Global.active_layers, по которому ищется следующий путь за краем (tracks у рельсов, roads у дороги)
static func advance(s: Dictionary, d: float, layer: StringName = &"tracks") -> Dictionary:
	var r := s.duplicate()
	var pc := _path(r.track)
	if pc == null:
		return {}
	var crv := pc.curve_of(r.route)
	var length := crv.get_baked_length()
	var target: float = r.dist + float(r.dir) * d
	if target >= 0.0 and target <= length:
		r.dist = target
		return r

	# Вышли за край трака
	var exiting_end := target > length
	var overflow: float = (target - length) if exiting_end else -target
	var edge := length if exiting_end else 0.0
	var et := crv.sample_baked_with_rotation(edge)
	var tan := (pc.path_node.global_basis * -et.basis.z).normalized()
	var out_dir := tan if exiting_end else -tan   # куда уходим с трака
	var probe := pc.path_node.to_global(et.origin) + out_dir * (overflow + PROBE_AHEAD)

	var next_track := _track_at(probe, r.track, pc.head_height(), layer)
	if next_track == null:
		return {}
	var npc := _path(next_track)
	var nroute := npc.entry_route(probe)
	if nroute < 0:
		return {}
	var ncrv := npc.curve_of(nroute)
	var nd := ncrv.get_closest_offset(npc.path_node.to_local(probe))
	r.track = next_track
	r.route = nroute
	r.dist = nd
	r.dir = 1.0 if _tangent(npc, nroute, nd).dot(out_dir) >= 0.0 else -1.0
	return r


static func _path(track: Entity) -> C_Path:
	if track == null or not is_instance_valid(track):
		return null
	var pc := track.get_comp(C_Path) as C_Path
	if pc == null or pc.path_node == null or pc.curve == null:
		return null
	return pc


static func _tangent(pc: C_Path, route: int, dist: float) -> Vector3:
	var t := pc.curve_of(route).sample_baked_with_rotation(dist)
	return (pc.path_node.global_basis * -t.basis.z).normalized()


static func _point(pc: C_Path, route: int, dist: float) -> Vector3:
	return pc.path_node.to_global(pc.curve_of(route).sample_baked_with_rotation(dist).origin)


## Трак под точкой (кроме того, с которого уходим)
static func _track_at(probe: Vector3, from_track: Entity, head_h: float, layer: StringName) -> Entity:
	var q := PhysicsRayQueryParameters3D.create(probe + Vector3.UP * (head_h + RAY_UP),
			probe + Vector3.DOWN * RAY_DOWN, Global.active_layers([layer]))
	var hit := from_track.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return null
	var node: Node = hit.collider
	while node != null and not node is Entity:
		node = node.get_parent()
	var e := node as Entity
	if e == null or e == from_track or _path(e) == null:
		return null
	return e
