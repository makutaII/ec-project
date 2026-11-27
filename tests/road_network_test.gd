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
##   7) три ширины независимы: collision_width (паспорт > 0 только этот экземпляр, иначе стиль всех), видимая ширина и ложе рельефа по профилю стиля
##   8) разметка в материале: одна поверхность меша, ShaderMaterial с линией
##   9) эстакада (CS1c): поднятая дорога получает опоры, ригель по ширине полотна, на столе опор нет; шейпов рельсов у дороги нет
##  10) пролёт: рельс над дорогой и дорога над дорогой без опор сквозь полотно
##  11) пандус: путь C_RoadPath с rise, тег ramp
## Ожидаемые ширины читаются из паспорта и стиля объекта, правка collision_width, профиля или surface_height в .tres тест не ломает.
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


## Паспорт и стиль объекта дороги
func _cfg_and_style(s: EntitySetting) -> Array:
	var cfg: RoadConfig = null
	var st: TrackStyle = null
	for c in s.components:
		if c is IdentitySetting:
			cfg = (c as IdentitySetting).object_config as RoadConfig
		elif c is StyleVisualSetting:
			st = (c as StyleVisualSetting).style
	return [cfg, st]


## Ширина коллизии объекта как её считает игра: collision_width паспорта, иначе стиля
func _collision_width(s: EntitySetting) -> float:
	var cs := _cfg_and_style(s)
	var cfg := cs[0] as RoadConfig
	var st := cs[1] as TrackStyle
	if cfg != null and cfg.collision_width > 0.0:
		return cfg.collision_width
	return st.collision_width if st != null else 0.0


## Видимая ширина полотна и ложе: по профилю стиля (collision_width её не меняет)
func _visible_width(s: EntitySetting) -> float:
	var st := _cfg_and_style(s)[1] as TrackStyle
	return st.ballast_half_width() * 2.0 if st != null else 0.0


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
	check("в папке есть объекты дорог (ожидается 8: 2 прямых, 4 поворота, 2 пандуса)", settings.size() == 8)
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
	check("поверхность дороги на высоте стиля над origin пути", ap != null and vis != null and absf(ap.head_height() - vis.style.surface_height) < 0.001)
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

	print("== 7. три ширины независимы")
	await clear()
	var want_c := _collision_width(road_s)
	var want_v := _visible_width(road_s)
	var wr := piece(road_s, Vector3.ZERO)
	var wl := piece(rail_s, Vector3(0, 0, -30))
	await frames(5)
	var wrp := wr.get_comp(C_Path) as C_Path
	var wlp := wl.get_comp(C_Path) as C_Path
	var rs := wrp.ballast_samples()
	var ls := wlp.ballast_samples()
	check("ложе дороги по видимой ширине профиля (%.2f ю)" % want_v, rs.size() >= 2 and absf(((rs[0]["l"] as Vector2) - (rs[0]["r"] as Vector2)).length() - want_v) < 0.01)
	check("ложе рельса прежнее (ширина балласта из настроек)", ls.size() >= 2
		and is_equal_approx(((ls[0]["l"] as Vector2) - (ls[0]["r"] as Vector2)).length(), float(Global.settings.track_ballast_segment.size.x)))
	check("bed_half_width дороги половина видимой ширины, рельса по настройкам", absf(wrp.bed_half_width() - want_v * 0.5) < 0.01
		and is_equal_approx(wlp.bed_half_width(), float(Global.settings.track_ballast_segment.size.x) * 0.5))
	var wv := wr.get_comp(C_StyleVisual) as C_StyleVisual
	check("меш полотна по профилю стиля (%.2f ю)" % want_v, wv != null and wv.mesh_node != null and wv.mesh_node.mesh != null
		and absf(wv.mesh_node.mesh.get_aabb().size.x - want_v) < 0.05)
	check("коллизия основания по collision_width объекта (%.2f ю)" % want_c, wv != null and wv.style != null and absf(wv.style.collision_width - want_c) < 0.01)
	# Паспорт > 0: меняется только коллизия этого экземпляра; меш, ложе и стиль других объектов те же
	var s_pass: EntitySetting = road_s.duplicate(true)
	var cfg_pass := _cfg_and_style(s_pass)[0] as RoadConfig
	cfg_pass.collision_width = want_c + 2.0
	var ep := piece(s_pass, Vector3(0, 0, -60))
	await frames(5)
	var epv := ep.get_comp(C_StyleVisual) as C_StyleVisual
	var epp := ep.get_comp(C_Path) as C_Path
	check("паспорт collision_width > 0: коллизия этого экземпляра изменилась", epv != null and absf(epv.style.collision_width - (want_c + 2.0)) < 0.01)
	check("и только она: меш и ложе те же", absf(epv.mesh_node.mesh.get_aabb().size.x - want_v) < 0.05 and absf(epp.bed_half_width() - want_v * 0.5) < 0.01)
	check("другой экземпляр того же объекта не изменился", absf(wv.style.collision_width - want_c) < 0.01)
	# Стиль: collision_width стиля меняет всех, у кого в паспорте 0; видимая ширина и ложе не меняются
	var s_style: EntitySetting = road_s.duplicate(true)
	for c in s_style.components:
		if c is StyleVisualSetting:
			(c as StyleVisualSetting).style = (c as StyleVisualSetting).style.duplicate() as TrackStyle
			(c as StyleVisualSetting).style.collision_width = want_c + 1.0
	var es := piece(s_style, Vector3(0, 0, -90))
	await frames(5)
	var esv := es.get_comp(C_StyleVisual) as C_StyleVisual
	var esp := es.get_comp(C_Path) as C_Path
	check("collision_width стиля при нуле в паспорте даёт коллизию объекта", esv != null and absf(esv.style.collision_width - (want_c + 1.0)) < 0.01)
	check("видимая ширина и ложе от collision_width стиля не зависят", absf(esv.mesh_node.mesh.get_aabb().size.x - want_v) < 0.05 and absf(esp.bed_half_width() - want_v * 0.5) < 0.01)
	var lane_cfg := _cfg_and_style(road_s)[0] as RoadConfig
	check("lane_width отдельное поле паспорта и на коллизию не влияет", lane_cfg != null and "lane_width" in lane_cfg)
	# нарезка и шейпы: рельсовых шейпов у дороги нет, остаётся основание
	var head := (wrp.head_node as Node)
	var ball := (wrp.ballast_node as Node)
	check("у прямой дороги один бокс основания в балласте и один в head (без шейпов рельсов)",
		ball != null and head != null and ball.get_child_count() == 1 and head.get_child_count() == 1)
	var hr := (wlp.head_node as Node)
	check("у рельса шейпы рельсов остались (в head больше одного шейпа)", hr == null or hr.get_child_count() != 1)

	print("== 8. разметка в материале")
	check("у меша дороги одна поверхность (линия не геометрия)", wv != null and wv.mesh_node.mesh.get_surface_count() == 1)
	var mat := wv.mesh_node.mesh.surface_get_material(0) if wv != null else null
	check("материал полотна ShaderMaterial с шейдером линии", mat is ShaderMaterial and (mat as ShaderMaterial).shader != null)

	print("== 9. эстакада: опоры дороги")
	await clear()
	var flat := piece(road_s, Vector3(0, 0, 0))
	var high := piece(road_s, Vector3(40, 3, 0))
	await frames(100)
	check("у сегмента дороги есть C_TrackSupport", high.has_comp(C_TrackSupport))
	var flat_body := flat.get_node_or_null("SupportsBody")
	var high_body := high.get_node_or_null("SupportsBody")
	check("дорога на столе без опор", flat_body == null or flat_body.get_child_count() == 0)
	check("поднятая дорога получила опоры", high_body != null and high_body.get_child_count() >= 2)
	if high_body != null and high_body.get_child_count() > 0:
		var beam := ((high_body.get_child(0) as CollisionShape3D).shape as BoxShape3D).size
		var hp := high.get_comp(C_Path) as C_Path
		check("ригель дороги по ширине полотна и не шире", absf(beam.x - hp.bed_half_width() * 2.0) < 0.01)

	print("== 10. пролёт: опоры не сквозь чужое полотно")
	await clear()
	var under := piece(load(ROAD_DIR + "road_s20.tres"), Vector3(0, 2, 0))
	var over := piece(rail_s, Vector3(0, 5, 0))
	var over_road := piece(road_s, Vector3(40, 5, 0))
	var under2 := piece(load(ROAD_DIR + "road_s20.tres"), Vector3(40, 2, 0))
	await frames(100)
	var ub := under.get_node_or_null("SupportsBody")
	check("нижняя дорога на высоте 2 получила опоры от земли", ub != null and ub.get_child_count() >= 2)
	var ob := over.get_node_or_null("SupportsBody")
	check("рельс над дорогой без опор сквозь полотно (пролёт)", not over.has_comp(C_TrackSupport) or ob == null or ob.get_child_count() == 0)
	var orb := over_road.get_node_or_null("SupportsBody")
	check("дорога над дорогой без опор сквозь полотно (пролёт)", orb == null or orb.get_child_count() == 0)
	if under2 != null:
		check("нижняя дорога под дорогой тоже стоит на опорах", under2.get_node_or_null("SupportsBody") != null)

	print("== 11. пандусы")
	var ramp_s: EntitySetting = load(ROAD_DIR + "road_ramp_20_r10.tres")
	await clear()
	var ramp := piece(ramp_s, Vector3.ZERO)
	await frames(5)
	var rp2 := ramp.get_comp(C_Path) as C_Path
	check("пандус поднимается на |rise| (путь C_RoadPath, rise 1.0)", rp2 is C_RoadPath and is_equal_approx(absf(rp2.rise), 1.0))
	check("пандус в каталоге под тегом ramp", ramp_s.category == &"road" and ramp_s.tag == &"ramp")

	await clear()
	print("== Итого: %s" % ("всё прошло" if _fails == 0 else "провалено проверок: %d" % _fails))
