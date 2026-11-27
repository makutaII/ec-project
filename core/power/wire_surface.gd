class_name WireSurface extends RefCounted

# XX claude-wire W7 (новый файл)
## Поверхности, на которых лежит провод (ATTN_23 §23.9): точка под клеммой и высота поверхности в точке.
## Общее для инструмента «Провод» (ручная прокладка) и автопроводки (AutoWire).

## Слои, по которым ищется поверхность: стол, трак, шпатлёвка и нижняя полка
const LAYERS := ["ground", "tracks", "plaster", "underside"]


## Точка на поверхности под клеммой (с подъёмом оси над ней, GlobalSetting.wire_lift): провод спускается к ней вертикально и дальше лежит.
## null: поверхности под клеммой нет или клемма уже у поверхности. Луч идёт вниз от клеммы, поэтому у клеммы на нижней полке плита над ней не мешает
static func drop(t: PowerTerminal) -> Variant:
	if not is_instance_valid(t) or not t.is_inside_tree():
		return null
	var from := t.global_position + Vector3.UP * 0.05
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 200.0, Global.active_layers(LAYERS))
	var hit := t.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return null
	var p: Vector3 = hit.position + Vector3.UP * Global.settings.wire_lift
	if p.y >= t.global_position.y - 0.05:
		return null
	return p


## Высота верха основной поверхности (стол, шпатлёвка, трак) в точке (x, z) с подъёмом оси: на месте ввода в плиту провод ложится на неё.
## Нет поверхности: плоскость стола
static func height_at(world: World3D, x: float, z: float, from_y := 300.0) -> float:
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, from_y, z), Vector3(x, -200.0, z), Global.active_layers(["ground", "tracks", "plaster"]))
	var hit := world.direct_space_state.intersect_ray(q)
	var y: float = 0.0 if hit.is_empty() else hit.position.y
	return y + Global.settings.wire_lift
