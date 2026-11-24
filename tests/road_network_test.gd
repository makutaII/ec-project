extends Node

# XX claude-car CS1 (новый файл)
## Тест сети дорог (ATTN_28, этап CS1). Запуск: открыть tests/road_network_test.tscn и нажать F6, смотреть Output.
## Сценарии:
##   1) слой roads: свой бит, не пересекается с остальными слоями
##   2) объекты data/roads/objects: категория road, паспорт RoadConfig, ширина полотна 8, сеть road
##   3) сущность дороги: C_RoadPath, сеть road, основание на слое roads (не tracks)
##   4) стык дороги с дорогой: соседи появляются
##   5) стык дороги с рельсом в одной точке: соседей нет, никто не заблокирован
##   6) дорога поверх рельса (пересечение): C_Blocked не вешается ни на дорогу, ни на рельс
##   7) ширина полотна одна (road_width): меш, коллизия и ложе рельефа (ballast_samples) 8 ю, у рельса прежние 3.2
##   8) светлая полоска: отдельная поверхность меша, штрихи разметки, with_ballast_width
## Красных строк E в Output быть не должно. Проверки перетаскивания (красный призрак, подсказка «Другая сеть»,
## магнит) руками в редакторе: см. ATTN_28 §28.7, этап CS1.

const ROAD_DIR := "res://data/roads/objects/"
const LAYER_NAMES := ["ground", "tracks", "sokets", "trains", "supports", "handles", "room", "ghost", "water", "plaster", "power", "underside", "roads"]

var _fails := 0


func piece(s: EntitySetting, pos: Vector3) -> Entity:
	var e: Entity = EntityFactory.new().create_from_setting(s)
	add_child(e)
	e.global_transform = Transform3D(Basis.IDENTITY, pos)   # прямые идут вдоль -Z, origin в середине кривой
	return e


func clear() -> void:
	for c in get_children():
		c.free()
	await get_tree().physics_frame


func frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func check(title: String, ok: bool) -> void:
	if not ok:
		_fails += 1
	print(("  OK    " if ok else "  FAIL  "), title)


func _neighbors(e: Entity) -> Array[Entity]:
	var sock := e.get_comp(C_Socket) as C_Socket
	if sock == null:
		var none: Array[Entity] = []
		return none
	return sock.get_connected_entities()


func _ready() -> void:
	print("== 1. слой roads")
	var seen := {}
	var unique := true
	for n in LAYER_NAMES:
		var bit := Global.active_layers([n])
		if bit == 0 or seen.has(bit):
			unique = false
		seen[bit] = n
	check("у каждого слоя свой ненулевой бит, roads среди них", unique)
	check("roads это бит 15 (слой 16)", Global.active_layers(["roads"]) == (1 << 15))

	print("== 2. объекты дорог")
	var settings: Array[EntitySetting] = []
	var dir := DirAccess.open(ROAD_DIR)
	check("папка %s открывается" % ROAD_DIR, dir != null)
	if dir != null:
		for f in dir.get_files():
			if f.ends_with(".tres"):
				var s := load(ROAD_DIR + f) as EntitySetting
				if s != null:
					settings.append(s)
	check("в папке есть объекты дорог (ожидается 6)", settings.size() == 6)
	for s in settings:
		var idc: IdentitySetting = null
		for c in s.components:
			if c is IdentitySetting:
				idc = c
		var cfg := idc.object_config as RoadConfig if idc else null
		check("%s: категория road, паспорт RoadConfig, сеть road, полотно 8" % s.get_key(),
			s.category == &"road" and cfg != null and cfg.network == &"road"
			and is_equal_approx(cfg.effective_collision_width(), 8.0))

	print("== 3. сущность дороги")
	var road_s: EntitySetting = load(ROAD_DIR + "road_s10.tres")
	var rail_s: EntitySetting = load("res://data/tracks/objects/g119.tres")
	var a := piece(road_s, Vector3.ZERO)
	await frames(5)
	var ap := a.get_comp(C_Path) as C_Path
	check("путь дороги это C_RoadPath", ap is C_RoadPath)
	check("сеть дороги road", C_Path.network_of(a) == &"road")
	check("сокет дороги в сети road", (a.get_comp(C_Socket) as C_Socket).network() == &"road")
	var vis := a.get_comp(C_StyleVisual) as C_StyleVisual
	check("основание дороги на слое roads и не на tracks", vis != null and vis.ballast != null
		and vis.ballast.collision_layer == Global.active_layers(["roads"]) and (vis.ballast.collision_layer & Global.active_layers(["tracks"])) == 0)
	check("поверхность дороги 0.3 над origin пути", ap != null and is_equal_approx(ap.head_height(), 0.3))
	var r0 := piece(rail_s, Vector3(0, 0, -30))
	await frames(5)
	check("сеть рельса rail", C_Path.network_of(r0) == &"rail")
	var rp := r0.get_comp(C_Path) as C_Path
	check("основание рельса осталось на слое tracks", rp != null and rp.ballast_node != null
		and rp.ballast_node.collision_layer == Global.active_layers(["tracks"]))

	print("== 4. стык дороги с дорогой")
	await clear()
	var r1 := piece(road_s, Vector3.ZERO)
	var r2 := piece(road_s, Vector3(0, 0, -10))
	await frames(10)
	check("первая дорога видит вторую соседом", _neighbors(r1).has(r2))
	check("вторая дорога видит первую соседом", _neighbors(r2).has(r1))
	check("дороги не блокируют друг друга при стыке", not r1.has_comp(C_Blocked) and not r2.has_comp(C_Blocked))

	print("== 5. стык дороги с рельсом")
	await clear()
	var road := piece(road_s, Vector3.ZERO)
	var rail := piece(rail_s, Vector3(0, 0, -(5.0 + 11.9 * 0.5)))   # концы в одной точке z = -5
	await frames(10)
	check("дорога не считает рельс соседом", not _neighbors(road).has(rail))
	check("рельс не считает дорогу соседом", not _neighbors(rail).has(road))
	check("дорога и рельс не блокируют друг друга", not road.has_comp(C_Blocked) and not rail.has_comp(C_Blocked))

	print("== 6. дорога поверх рельса")
	await clear()
	var road2 := piece(road_s, Vector3.ZERO)
	var rail2 := piece(rail_s, Vector3.ZERO)
	await frames(10)
	check("дорога поверх рельса не заблокирована", not road2.has_comp(C_Blocked))
	check("рельс под дорогой не заблокирован", not rail2.has_comp(C_Blocked))

	print("== 7. ширина полотна и ложе")
	await clear()
	var wr := piece(road_s, Vector3.ZERO)
	var wl := piece(rail_s, Vector3(0, 0, -30))
	await frames(5)
	var wrp := wr.get_comp(C_Path) as C_Path
	var wlp := wl.get_comp(C_Path) as C_Path
	var rs := wrp.ballast_samples()
	var ls := wlp.ballast_samples()
	check("ложе дороги: ширина образцов 8 ю", rs.size() >= 2 and is_equal_approx(((rs[0]["l"] as Vector2) - (rs[0]["r"] as Vector2)).length(), 8.0))
	check("ложе рельса прежнее (ширина балласта из настроек)", ls.size() >= 2
		and is_equal_approx(((ls[0]["l"] as Vector2) - (ls[0]["r"] as Vector2)).length(), float(Global.settings.track_ballast_segment.size.x)))
	check("bed_half_width дороги 4, рельса по настройкам", is_equal_approx(wrp.bed_half_width(), 4.0)
		and is_equal_approx(wlp.bed_half_width(), float(Global.settings.track_ballast_segment.size.x) * 0.5))
	var wv := wr.get_comp(C_StyleVisual) as C_StyleVisual
	check("меш полотна шириной road_width", wv != null and wv.mesh_node != null and wv.mesh_node.mesh != null
		and absf(wv.mesh_node.mesh.get_aabb().size.x - 8.0) < 0.05)
	check("коллизия основания шириной road_width", wv != null and wv.style != null and is_equal_approx(wv.style.collision_width, 8.0))

	print("== 8. светлая полоска")
	check("у меша дороги две поверхности: асфальт и полоска", wv != null and wv.mesh_node.mesh.get_surface_count() == 2)
	var solid := TrackMeshBuilder.marking_ranges(10.0, 0.0, 0.0)
	check("сплошная линия это один отрезок на весь кусок", solid.size() == 1 and is_equal_approx(solid[0].x, 0.0) and is_equal_approx(solid[0].y, 10.0))
	var dashes := TrackMeshBuilder.marking_ranges(10.0, 1.5, 1.5)
	var even := dashes.size() == 3
	if even:
		var gap01 := dashes[1].x - dashes[0].y
		var gap12 := dashes[2].x - dashes[1].y
		var edge := dashes[0].x + (10.0 - dashes[2].y)   # два края куска вместе дают один пробел на стыке
		even = is_equal_approx(gap01, gap12) and is_equal_approx(edge, gap01)
	check("штрихи 10 ю: три штриха, пробелы равны, на стыке тоже", even)
	var narrow := TrackStyle.with_ballast_width(wv.style, 6.0)
	var nx := 0.0
	for pt in narrow.ballast_profile:
		nx = maxf(nx, absf(pt.x))
	check("with_ballast_width: ширина 6 даёт полуширину 3, копия, исходный стиль цел", is_equal_approx(nx, 3.0) and narrow != wv.style)
	check("with_ballast_width: та же ширина возвращает тот же стиль", TrackStyle.with_ballast_width(wv.style, 8.0) == wv.style)
	check("у рельсового стиля полоски нет (marking_width 0)", TrackStyle.new().marking_width == 0.0)

	await clear()
	print("== Итого: %s" % ("всё прошло" if _fails == 0 else "провалено проверок: %d" % _fails))
