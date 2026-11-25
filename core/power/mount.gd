class_name Mount extends RefCounted

# XX claude-wire W4 (новый файл)
#####################
## Монтаж блоков (ATTN_23 §23.9, W4)
#####################
## Куда ставится блок: на плиту сверху (TOP, как раньше), на низ плиты (UNDER) или на боковую грань бруса рамы,
## подрамника и ножки (FRAME). Поверхность определяет коллайдер под курсором: тела на слое underside помечены метой META.
## Поза блока: ось Y блока вдоль нормали поверхности (у UNDER вниз: блок висит), spin это поворот вокруг нормали.
## Чистая логика: тестируется без игры (tests/mount_test).

enum Surface { TOP, UNDER, FRAME }

## Мета тела на слое underside: "UNDER" (тонкое тело под плитой) или "FRAME" (брус, ножка, кронштейн, царга)
const META := &"mount"
## UNDER: ближе этого к краю стола не ставим (ножки, брус и царги), u
const UNDER_MARGIN := 10.0
## FRAME: на верхнюю и нижнюю грани бруса не крепим (|нормаль.y| больше этого)
const FRAME_MAX_NORMAL_Y := 0.3


static func surface_of_collider(collider: Object) -> int:
	var n := collider as Node
	if n != null and n.has_meta(META):
		match String(n.get_meta(META)):
			"UNDER":
				return Surface.UNDER
			"FRAME":
				return Surface.FRAME
	return Surface.TOP


## Поверхность по позе блока (ось Y блока вверх, вниз или в сторону)
static func surface_of_basis(b: Basis) -> int:
	var y := b.y.normalized().y
	if y > 0.7:
		return Surface.TOP
	if y < -0.7:
		return Surface.UNDER
	return Surface.FRAME


## Базис блока: ось Y вдоль normal, затем поворот на spin вокруг неё. Для normal = UP это обычный поворот вокруг Y
static func basis_for(normal: Vector3, spin: float) -> Basis:
	var y := normal.normalized()
	var x0 := Vector3.RIGHT if absf(y.y) > 0.99 else Vector3.UP.cross(y).normalized()
	var z0 := x0.cross(y)
	return Basis(y, spin) * Basis(x0, y, z0)


## Поворот вокруг нормали, обратный basis_for
static func spin_of(b: Basis, normal: Vector3) -> float:
	var rel := basis_for(normal, 0.0).inverse() * b.orthonormalized()
	return atan2(-rel.x.z, rel.x.x)


## Причина, по которой блок здесь не встанет, или пусто. allowed: список Surface, где блок крепится
static func reason(surface: int, pos: Vector3, normal: Vector3, allowed: Array) -> String:
	if not allowed.has(surface):
		return "Блок здесь не крепится"
	match surface:
		Surface.UNDER:
			var m := UNDER_MARGIN
			for off in [Vector2(m, 0), Vector2(-m, 0), Vector2(0, m), Vector2(0, -m), Vector2(m, m), Vector2(-m, -m), Vector2(m, -m), Vector2(-m, m)]:
				if not LYM.contains(pos.x + off.x, pos.z + off.y):
					return "Слишком близко к краю стола: там ножки и рама"
		Surface.FRAME:
			if absf(normal.y) > FRAME_MAX_NORMAL_Y:
				return "К раме крепят к боковой грани бруса"
	return ""


## Блок ли это с монтажом (в паспорте есть MountDraggableSettings)
static func has_mount(setting: EntitySetting) -> bool:
	if setting == null:
		return false
	for c in setting.components:
		if c is MountDraggableSettings:
			return true
	return false


## Маска лучей постановки блока. При виде «Монтаж» (LYM.wiring_active) добавляется слой underside, а слои, где блок стоит
## сверху (стол, листы), остаются только пока плита показана: скрытая плита не заслоняет подстолье
static func pick_mask(setting: EntitySetting, mask: int) -> int:
	if not LYM.wiring_active or not has_mount(setting):
		return mask
	var under := Global.active_layers(['underside'])
	return (mask | under) if LYM.plate_visible else under
