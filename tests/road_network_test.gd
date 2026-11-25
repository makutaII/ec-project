extends Node

# XX claude-car CS1 (новый файл)
## Тест сети дорог (ATTN_28, этап CS1). Запуск: открыть tests/road_network_test.tscn и нажать F6, смотреть Output.
## Сценарии:
##   1) слой roads: свой бит, не пересекается с остальными слоями
##   2) объекты data/roads/objects: категория road, паспорт RoadConfig, сеть road
##   3) сущность дороги: C_RoadPath, сеть road, основание на слое roads (не tracks)
##   4) стык дороги с дорогой: соседи появляются
##   5) стык дороги с рельсом в одной точке: соседей нет, никто не заблокирован
##   6) дорога поверх рельса (пересечение): C_Blocked не вешается ни на дорогу, ни на рельс
##   7) ширина как у трака: коллизия из паспорта (иначе из стиля), меш и ложе рельефа (ballast_samples) следуют за ней, у рельса прежние
##   8) разметка в материале: одна поверхность меша, ShaderMaterial с линией, with_ballast_width
##   9) C_RoadBed: дорога сообщает рельефу о себе (TGM.terrain_changed), ложе под ней не ждёт жд трак
## Ожидаемая ширина читается из паспорта и стиля объекта, правка road_width или collision_width в .tres тест не ломает.
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


## Ширина полотна объекта дороги по его паспорту и стилю (как её считает игра): road_width, иначе collision_width паспорта, иначе стиля
func _expected_width(s: EntitySetting) -> float:
	var cfg: RoadConfig = null
	var st: TrackStyle = null
	for c in s.components:
		if c is IdentitySetting:
			cfg = (c as IdentitySetting).object_config as RoadConfig
		elif c is StyleVisualSetting:
			st = (c as StyleVisualSetting).style
	if cfg != null and cfg.road_width > 0.0:
		return cfg.road_width
	if cfg != null and cfg.collision_width > 0.0:
		return cfg.collision_width
	return st.collision_width if st != null else 0.0


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
		check("%s: категория road, паспорт RoadConfig, сеть road" % s.get_key(),
			s.category == &"road" and cfg != null and cfg.network == &"road")

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

	print("== 7. ширина как у трака")
	await clear()
	var want := _expected_width(road_s)
	var wr := piece(road_s, Vector3.ZERO)
	var wl := piece(rail_s, Vector3(0, 0, -30))
	await frames(5)
	var wrp := wr.get_comp(C_Path) as C_Path
	var wlp := wl.get_comp(C_Path) as C_Path
	var rs := wrp.ballast_samples()
	var ls := wlp.ballast_samples()
	check("ложе дороги по ширине объекта (%.2f ю)" % want, rs.size() >= 2 and absf(((rs[0]["l"] as Vector2) - (rs[0]["r"] as Vector2)).length() - want) < 0.01)
	check("ложе рельса прежнее (ширина балласта из настроек)", ls.size() >= 2
		and is_equal_approx(((ls[0]["l"] as Vector2) - (ls[0]["r"] as Vector2)).length(), float(Global.settings.track_ballast_segment.size.x)))
	check("bed_half_width дороги половина ширины, рельса по настройкам", absf(wrp.bed_half_width() - want * 0.5) < 0.01
		and is_equal_approx(wlp.bed_half_width(), float(Global.settings.track_ballast_segment.size.x) * 0.5))
	var wv := wr.get_comp(C_StyleVisual) as C_StyleVisual
	check("меш полотна той же ширины", wv != null and wv.mesh_node != null and wv.mesh_node.mesh != null
		and absf(wv.mesh_node.mesh.get_aabb().size.x - want) < 0.05)
	check("коллизия основания той же ширины", wv != null and wv.style != null and absf(wv.style.collision_width - want) < 0.01)
	# паспорт меняет только свой объект: поворот (collision_width 7 в паспорте) шире прямой, стиль общий и не изменился
	var curve_s: EntitySetting = load(ROAD_DIR + "road_r15_30.tres")
	var curve_want := _expected_width(curve_s)
	var wc := piece(curve_s, Vector3(0, 0, -60))
	await frames(5)
	var wcv := wc.get_comp(C_StyleVisual) as C_StyleVisual
	check("поворот: коллизия и меш по паспорту (%.2f ю)" % curve_want, wcv != null and absf(wcv.style.collision_width - curve_want) < 0.01
		and absf(wcv.mesh_node.mesh.get_aabb().size.x - curve_want) < 0.2)
	check("прямая осталась со стилем: паспорт поворота её не менял", wv != null and absf(wv.style.collision_width - want) < 0.01)

	print("== 8. разметка в материале")
	check("у меша дороги одна поверхность (линия не геометрия)", wv != null and wv.mesh_node.mesh.get_surface_count() == 1)
	var mat := wv.mesh_node.mesh.surface_get_material(0) if wv != null else null
	check("материал полотна ShaderMaterial с шейдером линии", mat is ShaderMaterial and (mat as ShaderMaterial).shader != null)
	var narrow := TrackStyle.with_ballast_width(wv.style, want - 2.0)
	var nx := 0.0
	for pt in narrow.ballast_profile:
		nx = maxf(nx, absf(pt.x))
	check("with_ballast_width: уже на 2 даёт полуширину на 1 меньше, копия, исходный стиль цел", absf(nx - (want * 0.5 - 1.0)) < 0.001 and narrow != wv.style)
	check("with_ballast_width: та же ширина возвращает тот же стиль", TrackStyle.with_ballast_width(wv.style, want) == wv.style)

	print("== 9. дорога сообщает рельефу о себе")
	await clear()
	var hits := [0]
	var on_terrain := func(_aabb: AABB) -> void: hits[0] += 1
	TGM.terrain_changed.connect(on_terrain)
	var nb := piece(road_s, Vector3.ZERO)
	await frames(5)
	check("у сегмента дороги есть C_RoadBed", nb.has_comp(C_RoadBed))
	check("постановка дороги шлёт TGM.terrain_changed", hits[0] > 0)
	var before: int = hits[0]
	nb.free()
	await frames(2)
	check("удаление дороги тоже шлёт TGM.terrain_changed", hits[0] > before)
	TGM.terrain_changed.disconnect(on_terrain)

	await clear()
	print("== Итого: %s" % ("всё прошло" if _fails == 0 else "провалено проверок: %d" % _fails))
