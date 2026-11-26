class_name Mount extends RefCounted

# XX claude-wire W4 (новый файл)
#####################
## Монтаж блоков (ATTN_23 §23.9, W4)
#####################
## Блок стоит на горизонтальной поверхности: на плите стола или на нижней полке (вторая столешница под основной по размеру
## подрамника, строит RoomBuilder при LayoutConfig.apron). Полка на слое underside, её тело помечено метой META = SHELF.
## Вид «Монтаж» (LYM.wiring_active) добавляет слой underside в лучи постановки блоков; скрытая плита их не заслоняет.
## Чистая логика: тестируется без игры (tests/mount_test).

## Мета тела на слое underside: "SHELF" (нижняя полка)
const META := &"mount"
## На полке блок ставим не ближе этого к её краю, u (блок 5 x 3 u)
const SHELF_MARGIN := 3.0


## Попал ли луч в нижнюю полку
static func on_shelf(collider: Object) -> bool:
	var n := collider as Node
	return n != null and n.has_meta(META) and String(n.get_meta(META)) == "SHELF"


## Причина, по которой блок здесь не встанет, или пусто. На плите сверху ограничений нет (как раньше)
static func reason(pos: Vector3, on_shelf_surface: bool) -> String:
	if not on_shelf_surface:
		return ""
	var polys := LYM.shelf_polygons()
	var m := SHELF_MARGIN
	for off in [Vector2.ZERO, Vector2(m, 0), Vector2(-m, 0), Vector2(0, m), Vector2(0, -m), Vector2(m, m), Vector2(-m, -m), Vector2(m, -m), Vector2(-m, m)]:
		var p := Vector2(pos.x + off.x, pos.z + off.y)
		var inside := false
		for poly in polys:
			if Geometry2D.is_point_in_polygon(p, poly):
				inside = true
				break
		if not inside:
			return "Слишком близко к краю нижней полки"
	return ""


## Блок ли это с монтажом (в паспорте есть MountDraggableSettings)
static func has_mount(setting: EntitySetting) -> bool:
	if setting == null:
		return false
	for c in setting.components:
		if c is MountDraggableSettings:
			return true
	return false


## Маска лучей постановки блока. При виде «Монтаж» (LYM.wiring_active) добавляется слой underside (полка), а слои, где блок стоит
## сверху (стол, листы), остаются только пока плита показана: скрытая плита не заслоняет полку
static func pick_mask(setting: EntitySetting, mask: int) -> int:
	if not LYM.wiring_active or not has_mount(setting):
		return mask
	var under := Global.active_layers(['underside'])
	return (mask | under) if LYM.plate_visible else under


## Маска лучей провода (WireTool): при виде «Монтаж» скрытая плита не заслоняет полку, на полку провод тоже ложится
static func wire_mask(mask: int) -> int:
	if not LYM.wiring_active:
		return mask
	var under := Global.active_layers(['underside'])
	return (mask | under) if LYM.plate_visible else ((mask & ~Global.active_layers(['ground'])) | under)
