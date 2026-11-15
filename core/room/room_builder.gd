class_name RoomBuilder extends Node3D

########################
## RoomRoot. Строит комнату из RoomConfig под собой. НЕ в EntitiesRoot и не сохраняется (TDD §14.1).
########################
## S2: greybox из коробок (пол, стены с проёмами, потолок, мебель-заглушки) + подмакетник.
## Подмакетник (Table): плиту строят секции-Entity (C_TableSection, слой ground, ATTN_23 T1), здесь только ножки на room.
## Он не скрывается кнопкой «Комната».
## Всё остальное (Room) на слое room (физика) и на visual layer Global.ROOM_VISUAL_LAYER.
## Про поезда комната не знает ничего. Карточек комнаты в Observe нет: видимость комнаты и потолка (F3 → Toggles) и смена комнаты
## (request_room) идут из кода. Observe зовёт только тени стен при входе и выходе.

## ⚡ XX claude-table T3. Пол, ножки и границы камеры пересобраны после изменения секций или высоты стола
signal room_layout_applied
## ⚡ Комнату показали или спрятали (CameraBounds выключает ограничение)
signal room_visible_changed(on: bool)
## Комнату заменили (switch_room): границы камеры и небо надо перечитать
signal room_changed(id: StringName)
## ⚡Состояние управляемых объектов комнаты задано извне (загрузка сейва): карточки Observe → Light обновляются
signal room_controls_changed

@export var config: RoomConfig
## Стены и потолок не отбрасывают тень: иначе низкое солнце затемнит стол. Окно и рама в S4
@export var walls_cast_shadow := false
## В режиме Observe стены отбрасывают тень: на столе виден рисунок окна. В остальных режимах свет ровный
@export var window_shadows_in_observe := true
## Временный свет для проверки масштаба. Включать, только если в главной сцене нет своего солнца
@export var temp_light := false

var visuals: Node3D    # пол, стены, потолок, мебель
var ceiling: Node3D
var _ceiling_mesh: MeshInstance3D   # плита потолка: скрытая в Observe, она всё равно отбрасывает тень (закрывает солнце сверху)
var table: Node3D
var _layout_dirty := false
var _room_lights: Node3D   # потолочные лампы RoomConfig.lamps: не часть visuals, чтобы скрытие комнаты (F3 → Toggles) не гасило свет

var _mats := {}
var _walls: Array[MeshInstance3D] = []   # стены, рама, шторы и подоконник: тень только в Observe
var _decor: RoomDecor
var _controls := RoomControlRegistry.new()   # управляемые объекты активной комнаты (ATTN_25 §25.6), у процедурной пусто
var _root: RoomRoot   # корень сцены комнаты (RoomConfig.scene), null у процедурной комнаты
var _wall_col := Color(0.80, 0.79, 0.76)
var _room_visible := true
var _ceiling_visible := false
var _walls_shadow_now := false

const COL_CEILING := Color(0.90, 0.90, 0.88)
const COL_TABLE := Color(0.62, 0.50, 0.38)
const COL_TABLE_LEG := Color(0.45, 0.36, 0.28)

## Лампа дневного света (RoomConfig.lamps): холодный белый, широкий конус вниз. Энергия у каждой лампы своя (в паспорте комнаты).
## Мир в см: bias и дальность считаются в см, значения теней как у лампы над столом
const LAMP_COLOR := Color(0.90, 0.95, 1.0)
const LAMP_RANGE := 600.0
const LAMP_ANGLE := 80.0
const LAMP_SOFT := 15.0       # light_size: размер источника, мягкость тени (трубка длинная, не точка)

## Мебель-заглушки. size: X, Y(высота), Z. xz: центр на полу. По §14.4
const PROPS := [
	{"name": "Bed", "size": Vector3(90, 45, 200), "xz": Vector2(-195, -90), "color": Color(0.55, 0.62, 0.78)},
	{"name": "Desk", "size": Vector3(60, 75, 120), "xz": Vector2(210, 40), "color": Color(0.72, 0.60, 0.45)},
	{"name": "Chair", "size": Vector3(40, 45, 40), "xz": Vector2(160, 40), "color": Color(0.50, 0.50, 0.55)},
	{"name": "Wardrobe", "size": Vector3(100, 200, 50), "xz": Vector2(-190, 165), "color": Color(0.66, 0.55, 0.42)},
	{"name": "Shelf", "size": Vector3(80, 180, 30), "xz": Vector2(200, -175), "color": Color(0.70, 0.58, 0.40)},
	{"name": "Rug", "size": Vector3(160, 1, 110), "xz": Vector2(0, 125), "color": Color(0.78, 0.45, 0.40), "collide": false},
]


func _ready() -> void:
	if config == null:
		config = RoomConfig.new()
	if Global.fast_debug:
		# Режим быстрой загрузки: комнату не строим, подмакетником служит скрытый WoodFloor из сцены
		print("[FAST] комната не строится, пол WoodFloor")
		_use_wood_floor()
		return
	add_to_group(&"room_root")
	_walls_shadow_now = walls_cast_shadow
	build()
	_connect_observe()
	_connect_gfx()
	LYM.layout_changed.connect(_on_layout_changed)   # XX claude-table T3: секции и высота стола


## Debug: включает старую большую землю (WoodFloor) вместо подмакетника и комнаты
func _use_wood_floor() -> void:
	var f := get_tree().root.find_child("WoodFloor", true, false) as Node3D
	if f == null:
		push_warning("RoomBuilder: WoodFloor не найден, в fast_debug нет земли")
		return
	f.visible = true
	var shape := f.find_child("CollisionShape3D", true, false) as CollisionShape3D
	if shape:
		shape.set_deferred("disabled", false)


## Тени стен в Observe. Ищем по группе: ObserveController живёт в сцене UI, а %-имена видны только внутри своей сцены
func _connect_observe() -> void:
	await get_tree().process_frame   # контроллер встаёт в группу в своём _ready
	var oc = get_tree().get_first_node_in_group(&"observe_controller")
	if oc:
		oc.observe_entered.connect(func(): _set_observe_shadows(true))
		oc.observe_exited.connect(func(): _set_observe_shadows(false))
	else:
		push_warning("RoomBuilder: ObserveController не найден, тени стен в Observe не переключаются")


## Лампочка светится по GFX.lamp_changed, мелочи прячутся по QualityPreset.room_detail_lod
func _connect_gfx() -> void:
	await get_tree().process_frame
	GFX.lamp_changed.connect(_on_lamp_changed)
	GFX.quality_changed.connect(func(_id): _apply_detail())
	if _decor:
		_decor.set_lamp_glow(GFX.is_lamp_on())
	if _root:
		_root.set_lamp_glow(GFX.is_lamp_on())
	_apply_detail()


func _on_lamp_changed(on: bool) -> void:
	if _decor:
		_decor.set_lamp_glow(on)
	if _root:
		_root.set_lamp_glow(on)


func _apply_detail() -> void:
	var q: QualityPreset = GFX.get_quality()
	var lod := q.room_detail_lod if q else 1
	if _decor:
		_decor.set_detail(lod)
	if _root:
		_root.set_detail(lod)


## Потолочные лампы комнаты (из сцены или из RoomConfig.lamps). null: ламп нет. Для корректора графики (GfxLab)
func get_room_lights() -> Node3D:
	return _room_lights if is_instance_valid(_room_lights) else null


## Тень оболочки (стены, рама, шторы, потолок) вручную: корректор графики (GfxLab) включает и выключает её птичкой
func set_shell_shadows(on: bool) -> void:
	_walls_shadow_now = on
	set_walls_cast_shadow(on)


## Вернуть обычное правило тени оболочки: тень только в Observe (после выхода из корректора графики)
func apply_observe_shadows(observe: bool) -> void:
	_set_observe_shadows(observe)


## Тень стен, рамы и штор: рисунок окна на столе только в Observe
func _set_observe_shadows(on: bool) -> void:
	_walls_shadow_now = window_shadows_in_observe if on else walls_cast_shadow
	set_walls_cast_shadow(_walls_shadow_now)


## Пересобрать всё (после смены config). Стол тоже: при игре лучше rebuild_room()
func build() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_room_lights = null   # освобождён вместе с остальными детьми
	_mats.clear()
	_build_table()
	_build_room()
	if config.show_stats:
		GFX.set_stats_shown(true)

	if temp_light:
		var l := DirectionalLight3D.new()
		l.name = "TempSun"
		l.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
		l.shadow_enabled = true
		l.directional_shadow_max_distance = 700.0
		add_child(l)


## Пересобрать только комнату (смена варианта), стол с вагонами не трогаем
func rebuild_room() -> void:
	if visuals:
		remove_child(visuals)
		visuals.queue_free()
	_mats.clear()
	_build_room()


## Dev (только запуск из редактора): записывает текущую процедурную комнату в сцену data/models/room_<id>/room_<id>.tscn
## и карточку data/rooms/cards/<id>.tres. Со следующего запуска RoomCatalog берёт сцену вместо кода. Возвращает путь сцены или "".
## Структура сцены описана в RoomRoot. Живую комнату это не меняет: в сцену уходят копии нод (ресурсы общие)
func save_room_scene() -> String:
	if not OS.has_feature("editor"):
		push_warning("RoomBuilder: сохранить комнату в сцену можно только при запуске из редактора")
		return ""
	if _root != null:
		push_warning("RoomBuilder: комната %s уже из сцены, правьте её tscn в редакторе" % config.id)
		return ""
	if visuals == null or not is_instance_valid(visuals):
		return ""
	var id := String(config.id)
	var dir := RoomCatalog.model_dir(config.id)
	var scene_path := RoomCatalog.scene_path(config.id)
	var passport_path := "%s/%s.tres" % [RoomCatalog.CARDS_DIR, id]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RoomCatalog.CARDS_DIR))

	var root := RoomRoot.new()
	root.name = id
	var named := {}   # Floor, Ceiling, DecorT2, DecorT3, FakeAO
	var shell := Node3D.new()
	shell.name = RoomRoot.SHELL
	var decor := Node3D.new()
	decor.name = "Decor"
	for n in visuals.get_children():
		var copy := n.duplicate()
		if String(n.name) in ["Floor", "Ceiling", "DecorT2", "DecorT3", "FakeAO"]:
			named[String(n.name)] = copy
		elif _has_shell_mesh(n):
			shell.add_child(copy)
		else:
			decor.add_child(copy)
	for key in ["Floor", "Shell", "Ceiling", "Decor", "DecorT2", "DecorT3", "FakeAO"]:
		if key == "Shell":
			root.add_child(shell)
		elif key == "Decor":
			root.add_child(decor)
		elif named.has(key):
			root.add_child(named[key])
	if is_instance_valid(_room_lights):
		var lights := _room_lights.duplicate()
		lights.name = RoomRoot.LIGHTS
		root.add_child(lights)
	_set_owner_rec(root, root)

	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err != OK:
		push_warning("RoomBuilder: PackedScene.pack не удался (%d)" % err)
		root.free()
		return ""
	err = ResourceSaver.save(packed, scene_path)
	root.free()
	if err != OK:
		push_warning("RoomBuilder: не записан %s (%d)" % [scene_path, err])
		return ""

	var pc := config.duplicate() as RoomConfig
	pc.lamps = []
	pc.variants = {}
	for b in RoomCatalog.BUILTIN:
		if b.id == config.id:
			pc.title = b.title
			pc.tip = b.tip
			pc.dev_only = bool(b.get("dev_only", false))
	pc.scene = ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	err = ResourceSaver.save(pc, passport_path)
	if err != OK:
		push_warning("RoomBuilder: не записан %s (%d)" % [passport_path, err])
		return ""
	print("[ROOM] записано: %s и %s. Перезапустите игру: комната возьмётся из сцены" % [scene_path, passport_path])
	return scene_path


func _has_shell_mesh(n: Node) -> bool:
	if n is MeshInstance3D and ((n as MeshInstance3D).layers & _shell_layer()):
		return true
	for c in n.get_children():
		if _has_shell_mesh(c):
			return true
	return false


func _set_owner_rec(n: Node, o: Node) -> void:
	for c in n.get_children():
		c.owner = o
		_set_owner_rec(c, o)


func _build_room() -> void:
	_walls.clear()
	ceiling = null
	_ceiling_mesh = null
	_decor = null
	_root = null
	_controls = RoomControlRegistry.new()
	visuals = Node3D.new()
	visuals.name = "Room"
	add_child(visuals)
	_clear_room_lights()
	if config.scene:
		_build_from_scene()
	elif config.shape == &"none":
		pass   # стенд: комнаты нет, только стол
	else:
		_build_room_lights()
		_build_greybox()
	# Состояние переживает пересборку
	visuals.visible = _room_visible
	_apply_height_offset()
	_apply_ceiling()
	set_walls_cast_shadow(_walls_shadow_now)
	_apply_detail()
	if GFX.lab_mode:
		GFX.lab.apply_room_flags()   # новые узлы комнаты получают птички корректора


## Комната из сцены (RoomConfig.scene, корень RoomRoot): лампы выносятся рядом с Room, остальное лежит в visuals
func _build_from_scene() -> void:
	var inst := config.scene.instantiate()
	var r := inst as RoomRoot
	if r == null:
		push_warning("RoomBuilder: корень сцены комнаты %s не RoomRoot, слои, потолок и лампы не настроены" % config.id)
		visuals.add_child(inst)
		return
	_root = r
	r.setup(_vis_layer(), _shell_layer())
	_controls = RoomControlRegistry.collect(r, String(config.id))   # до take_lights: метки ламп лежат в ветке Lights
	for w in _controls.warnings:
		push_warning("RoomBuilder: комната %s: %s" % [config.id, w])
	_room_lights = r.take_lights()
	if _room_lights:
		add_child(_room_lights)
	visuals.add_child(r)
	_walls.append_array(r.get_wall_meshes())
	ceiling = r.get_ceiling()
	_ceiling_mesh = r.get_ceiling_mesh()


## Управляемые объекты активной комнаты (пустой реестр у процедурной). Читает Observe → Light
func get_controls() -> RoomControlRegistry:
	return _controls


## Значение управления (0..1), для сейва и скриптов. false: такого управления нет
func set_control_value(id: StringName, value: float, instant := true) -> bool:
	var d := _controls.by_id(id)
	if d == null:
		return false
	d.set_value(value, instant)
	return true


## Переключатель из карточки Observe (TOGGLE, SLIDER, MECH). false: такого управления нет
func set_control_on(id: StringName, on: bool) -> bool:
	var d := _controls.by_id(id)
	if d == null:
		return false
	d.set_on(on)
	return true


## Состояние для сейва: id -> значение для управлений со scope = observe (остальные меняет только студия)
func get_control_state() -> Dictionary:
	var out := {}
	for d in _controls.for_scope(RoomControl.Scope.OBSERVE):
		out[d.id] = d.value
	return out


## Из сейва: сначала управления Observe в начальные значения, затем значения из state. Неизвестные id молча пропускаются
## (комнату могли изменить). Пустой state (старый сейв) это начальные значения
func set_control_state(state: Dictionary) -> void:
	var by_id := {}   # ключи сейва могут прийти как String или StringName
	for k in state:
		by_id[StringName(str(k))] = state[k]
	for d in _controls.for_scope(RoomControl.Scope.OBSERVE):
		d.reset()
		if by_id.has(d.id):
			d.set_value(float(by_id[d.id]), true)
	room_controls_changed.emit()


## Механизмы комнаты ходят по времени (MechanismConfig.duration)
func _process(delta: float) -> void:
	if _controls.is_moving():
		_controls.tick(delta)


## Id текущей комнаты (в сейв)
func get_room_id() -> StringName:
	return config.id if config else RoomCatalog.DEFAULT_ID


## Источники смены активной комнаты (ATTN_25 §25.3)
const SRC_START := &"start"        # выбор игрока или аргумент --room при запуске
const SRC_SCENARIO := &"scenario"  # сценарий
const SRC_LOAD := &"load"          # загрузка сейва: возвращает комнату сейва
const SRC_ADMIN := &"admin"        # админ (Global.debug_mode) через Room Studio


## Может ли источник менять комнату. Игрок в сессии менять не может: любой другой источник (Observe, Build, Operate) отклоняется
static func can_change(source: StringName) -> bool:
	match source:
		SRC_START, SRC_SCENARIO, SRC_LOAD:
			return true
		SRC_ADMIN:
			return Global.debug_mode
	return false


## Единственный путь смены активной комнаты. true: комната теперь id (в том числе была уже такой).
## Отказ (чужой источник, неизвестный id) пишет push_warning и ничего не меняет. Исключение: загрузка сейва с неизвестным id
## (комнату убрали или переименовали) ставит комнату по умолчанию
func request_room(id: StringName, source: StringName) -> bool:
	if not can_change(source):
		push_warning("RoomBuilder.request_room: источник '%s' не может менять комнату (запрошена '%s')" % [source, id])
		return false
	if Global.fast_debug:
		return false   # в --fast комнаты нет
	var target := id
	if not RoomCatalog.has(target):
		if source != SRC_LOAD:
			push_warning("RoomBuilder.request_room: комнаты '%s' нет в каталоге" % id)
			return false
		push_warning("RoomBuilder.request_room: комнаты '%s' из сейва нет в каталоге, берём '%s'" % [id, RoomCatalog.DEFAULT_ID])
		target = RoomCatalog.DEFAULT_ID
	switch_room(target)
	return get_room_id() == target


## Заменить комнату целиком (старая освобождается, в памяти одна). Стол пересобирается по паспорту новой комнаты.
## До _ready только подменяет паспорт (стартовую сборку сделает _ready). Варианты цветов переносятся
## Внутренний метод: снаружи звать request_room
func switch_room(id: StringName) -> void:
	if Global.fast_debug:
		return
	if config != null and config.id == id:
		return
	var nc := RoomCatalog.make(id)
	if config != null:
		nc.variants = config.variants.duplicate()
	config = nc
	if not is_node_ready() or not is_in_group(&"room_root"):
		return
	build()
	room_changed.emit(config.id)
	GFX.set_state(GFX.get_state())   # небо и лампа пересобранной комнаты


## Смена варианта (слоты wall, bedding, curtains, posters, см. RoomDecor.VARIANTS)
func set_variant(slot: String, value: String) -> void:
	if config.variants.get(slot, "") == value:
		return
	config.variants[slot] = value
	rebuild_room()


## XX claude-table T0. Заменить все варианты разом (загрузка сейва): комната пересобирается один раз
func set_variants(v: Dictionary) -> void:
	if config.variants == v:
		return
	config.variants = v.duplicate()
	if is_node_ready() and is_in_group(&"room_root"):
		rebuild_room()


## Границы камеры. Верх сдвигается вместе с потолком при смене высоты стола (T3), низ остаётся над столешницей
func get_bounds() -> AABB:
	var b := config.bounds
	if config.shape != &"none":
		b.size.y = maxf(b.size.y + floor_offset(), 10.0)
	return b


func set_room_visible(on: bool) -> void:
	_room_visible = on
	if visuals:
		visuals.visible = on
	room_visible_changed.emit(on)


## Тень от стен (рисунок окна на столе). Потолок и небо в окне тень не отбрасывают никогда
func set_walls_cast_shadow(on: bool) -> void:
	var mode := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for m in _walls:
		m.cast_shadow = mode
	_apply_ceiling()


## Потолок: нода всегда активна, а плита либо видна (и отбрасывает тень), либо скрыта, но отбрасывает тень, когда стены
## её отбрасывают (Observe). Без этого солнце заходило поверх стен и на стенах была видна верхняя граница тени
func _apply_ceiling() -> void:
	if ceiling == null or _ceiling_mesh == null:
		return
	ceiling.visible = true
	if _walls_shadow_now:
		_ceiling_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if _ceiling_visible \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	else:
		_ceiling_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ceiling_mesh.visible = _ceiling_visible or _walls_shadow_now


func set_ceiling_visible(on: bool) -> void:
	_ceiling_visible = on
	_apply_ceiling()


func is_room_visible() -> bool:
	return _room_visible


func is_ceiling_visible() -> bool:
	return _ceiling_visible


# ==========================================
# Подмакетник
# ==========================================

func _build_table() -> void:
	table = Node3D.new()
	table.name = "Table"
	add_child(table)
	_build_supports()


## XX claude-table T3. Секции или высота изменились. Много событий за кадр (загрузка сейва) сливаются в одну пересборку
func _on_layout_changed() -> void:
	if _layout_dirty:
		return
	_layout_dirty = true
	_apply_layout.call_deferred()


func _apply_layout() -> void:
	_layout_dirty = false
	if not is_inside_tree() or table == null:
		return
	_apply_height_offset()
	_build_supports()
	room_layout_applied.emit()


## Пол и всё, что к нему крепится (стены, потолок, мебель, лампы), смещаются так, чтобы верх стола был на y = 0, а пол на -высота.
## Комната строится от RoomConfig.floor_y, поэтому достаточно сдвинуть корни узлов (пересборка комнаты не нужна)
func _apply_height_offset() -> void:
	var dy := floor_offset()
	if is_instance_valid(visuals):
		visuals.position.y = dy
	if is_instance_valid(_room_lights):
		_room_lights.position.y = dy


## Насколько комната сдвинута от паспортного floor_y из-за высоты стола (LayoutConfig.height)
func floor_offset() -> float:
	return -LYM.config.height - config.floor_y


## Ножки по футпринту (LYM.footprint): от низа плиты до пола. Стол v1 (200 x 100, высота 50) даёт те же 4 ножки
func _build_supports() -> void:
	if table == null:
		return
	for c in table.get_children():
		table.remove_child(c)
		c.queue_free()
	# XX claude-table T4: вид опор из LayoutConfig (ножки, рама, кронштейны), детали строит план TableSupports.parts
	var room_layer := Global.active_layers(['room'])
	for part in TableSupports.parts(int(LYM.config.support), LYM.footprint(), LYM.config.height, LYM.plate_thickness(),
			config.table_leg, config):
		var mi := _box(table, part["name"], part["size"], part["center"], COL_TABLE_LEG, room_layer, 1, true)
		if mi != null:
			var b := part["basis"] as Basis
			if not b.is_equal_approx(Basis.IDENTITY):
				var body := mi.get_parent() as Node3D
				var tf := body.transform
				tf.basis = b
				body.transform = tf


# ==========================================
# Greybox
# ==========================================

func _build_greybox() -> void:
	var c := config
	var t := c.wall_thickness
	var fy := c.floor_y
	var room_layer := Global.active_layers(['room'])
	var vis := _vis_layer()

	var attic := c.shape == &"attic"
	_decor = RoomAttic.new(c, vis, _lamp_height()) if attic else RoomDecor.new(c, vis, _lamp_height())
	_wall_col = _decor.wall_color()

	var floor_mi := _box(visuals, "Floor", Vector3(c.size.x + 2.0 * t, t, c.size.z + 2.0 * t), Vector3(0.0, fy - t * 0.5, 0.0),
			_decor.floor_color(), room_layer, vis, true)
	floor_mi.material_override = _parquet_mat(_decor.floor_color())

	if attic:
		# Мансарда: оболочку (стены, скос, ниша двери, окна) строит RoomAttic
		var ra := _decor as RoomAttic
		ra.floor_material = floor_mi.material_override
		ra.build_shell(visuals)
		for part in ra.shell_parts:
			_walls.append(part)
	else:
		_wall_z(-1.0, c.window)   # север: окно
		_wall_z(1.0, c.door)      # юг: дверь
		_wall_x(-1.0)
		_wall_x(1.0)
		_build_window_frame()
		_build_sky_card()
	_build_fake_ao()

	# Потолок: отдельной нодой, по умолчанию скрыт, без коллизии. В мансарде плоский только западнее roof_top_x
	ceiling = Node3D.new()
	ceiling.name = "Ceiling"
	visuals.add_child(ceiling)
	var cx0 := -c.size.x * 0.5 - t
	var cx1 := c.roof_top_x if attic else c.size.x * 0.5 + t
	_ceiling_mesh = _box(ceiling, "CeilingSlab", Vector3(cx1 - cx0, t, c.size.z + 2.0 * t),
			Vector3((cx0 + cx1) * 0.5, fy + c.size.y + t * 0.5, 0.0), COL_CEILING, 0, _shell_layer(), false)
	_apply_ceiling()

	if not c.furnished:
		return

	# Мебель: коллизия простой коробкой (слой room), внешний вид строит RoomDecor (в мансарде RoomAttic и коллизии тоже)
	if not attic:
		for p in PROPS:
			if p.get("collide", true):
				var sz: Vector3 = p.size
				var xz: Vector2 = p.xz
				_collider(visuals, p.name, sz, Vector3(xz.x, fy + sz.y * 0.5, xz.y), room_layer)

	_decor.build(visuals)
	for part in _decor.window_parts:
		_walls.append(part)


## Стена вдоль X на z = sgn * (hz + t/2) с необязательным проёмом {x, w, sill, h}
func _wall_z(sgn: float, op: Dictionary) -> void:
	var c := config
	var hx := c.size.x * 0.5
	var cz := sgn * (c.size.z * 0.5 + c.wall_thickness * 0.5)
	var x0 := -hx - c.wall_thickness
	var x1 := hx + c.wall_thickness
	var y0 := c.floor_y
	var y1 := c.floor_y + c.size.y
	var nm := "WallS" if sgn > 0.0 else "WallN"
	if op.is_empty():
		_slab(nm, x0, x1, y0, y1, cz)
		return
	var l: float = op.x - op.w * 0.5
	var r: float = op.x + op.w * 0.5
	var s0: float = y0 + op.sill
	var s1: float = s0 + op.h
	if op.sill > 0.0:
		_slab(nm + "_Below", x0, x1, y0, s0, cz)
	if s1 < y1:
		_slab(nm + "_Above", x0, x1, s1, y1, cz)
	_slab(nm + "_Left", x0, l, s0, s1, cz)
	_slab(nm + "_Right", r, x1, s0, s1, cz)


## Стена вдоль Z (между северной и южной, углы принадлежат им)
func _wall_x(sgn: float) -> void:
	var c := config
	var cx := sgn * (c.size.x * 0.5 + c.wall_thickness * 0.5)
	_walls.append(_box(visuals, "WallE" if sgn > 0.0 else "WallW",
			Vector3(c.wall_thickness, c.size.y, c.size.z), Vector3(cx, c.floor_y + c.size.y * 0.5, 0.0),
			_wall_col, Global.active_layers(['room']), _shell_layer(), walls_cast_shadow))


## Паркет процедурным шейдером (без текстур и геометрии): доски 12 × 100 см вразбежку, лёгкий разброс оттенка и тёмные швы.
## Швы гаснут на расстоянии (fwidth), чтобы не рябило. Рисунок считается по мировым координатам XZ
const PARQUET_SHADER := """
shader_type spatial;
uniform vec4 base_color : source_color = vec4(0.74, 0.58, 0.40, 1.0);
uniform float plank_w = 12.0;
uniform float plank_len = 100.0;
uniform float groove = 0.35;
uniform float tint = 0.07;
varying vec3 wp;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float row = floor(wp.z / plank_w);
	float off = hash(vec2(row, 3.0)) * plank_len;
	float colm = floor((wp.x + off) / plank_len);
	float fz = wp.z / plank_w - row;
	float fx = (wp.x + off) / plank_len - colm;
	float gap = min(min(fz, 1.0 - fz) * plank_w, min(fx, 1.0 - fx) * plank_len);
	float g = 1.0 - smoothstep(0.0, groove, gap);
	float fw = max(fwidth(wp.x), fwidth(wp.z));
	g *= 1.0 - smoothstep(0.3, 1.2, fw);
	float t = (hash(vec2(row, colm)) - 0.5) * 2.0 * tint;
	vec3 c = base_color.rgb * (1.0 + t);
	c = mix(c, c * 0.55, g * 0.85);
	ALBEDO = c;
	ROUGHNESS = 0.85;
}
"""
var _parquet_shader: Shader


func _parquet_mat(color: Color) -> ShaderMaterial:
	if _parquet_shader == null:
		_parquet_shader = Shader.new()
		_parquet_shader.code = PARQUET_SHADER
	var m := ShaderMaterial.new()
	m.shader = _parquet_shader
	m.set_shader_parameter("base_color", color)   # Color, а не Vector3: иначе source_color не переведёт sRGB в linear и пол выцветает
	return m


## Ложный AO (ATTN_14 §14.13): мягкое затемнение у плинтуса и в вертикальных углах. SSAO в Clean выключен и почти ничего
## не давал, а плоские стены без этого читаются как нарисованные. 9 полупрозрачных квадов без теней, на visual-слое комнаты.
## Стена с дверью (юг) пропущена: квад повис бы в проёме
const AO_COLOR := Color(0.05, 0.07, 0.16)
const AO_ALPHA := 0.55
const AO_FLOOR_H := 60.0      # высота полосы у пола, см
const AO_CORNER_W := 32.0     # ширина полосы в вертикальном углу, см
const AO_GAP := 0.3           # отступ от стены против z-fighting, см


func _build_fake_ao() -> void:
	var c := config
	var hx := c.size.x * 0.5
	var hz := c.size.z * 0.5
	var y0 := c.floor_y
	var h := c.size.y
	var root := Node3D.new()
	root.name = "FakeAO"
	visuals.add_child(root)
	var tex_floor := _ao_tex(true)
	var tex_corner := _ao_tex(false)
	# В мансарде восточная сторона скошена: вертикальные квады там повисли бы за крышей, их нет
	var east := c.shape != &"attic"
	# Полосы у пола: север, запад, восток (rot_y: куда смотрит нормаль квада внутрь комнаты)
	_ao_quad(root, "FloorN", Vector2(c.size.x, AO_FLOOR_H), Vector3(0.0, y0 + AO_FLOOR_H * 0.5, -hz + AO_GAP), 0.0, tex_floor, false)
	_ao_quad(root, "FloorW", Vector2(c.size.z, AO_FLOOR_H), Vector3(-hx + AO_GAP, y0 + AO_FLOOR_H * 0.5, 0.0), PI * 0.5, tex_floor, false)
	if east:
		_ao_quad(root, "FloorE", Vector2(c.size.z, AO_FLOOR_H), Vector3(hx - AO_GAP, y0 + AO_FLOOR_H * 0.5, 0.0), -PI * 0.5, tex_floor, false)
	# Вертикальные углы: на северной стене и на боковых стенах у севера и юга (градиент от угла)
	var w := AO_CORNER_W
	_ao_quad(root, "CornerN_W", Vector2(w, h), Vector3(-hx + w * 0.5, y0 + h * 0.5, -hz + AO_GAP), 0.0, tex_corner, false)
	_ao_quad(root, "CornerW_N", Vector2(w, h), Vector3(-hx + AO_GAP, y0 + h * 0.5, -hz + w * 0.5), PI * 0.5, tex_corner, true)
	_ao_quad(root, "CornerW_S", Vector2(w, h), Vector3(-hx + AO_GAP, y0 + h * 0.5, hz - w * 0.5), PI * 0.5, tex_corner, false)
	if east:
		_ao_quad(root, "CornerN_E", Vector2(w, h), Vector3(hx - w * 0.5, y0 + h * 0.5, -hz + AO_GAP), 0.0, tex_corner, true)
		_ao_quad(root, "CornerE_N", Vector2(w, h), Vector3(hx - AO_GAP, y0 + h * 0.5, -hz + w * 0.5), -PI * 0.5, tex_corner, false)
		_ao_quad(root, "CornerE_S", Vector2(w, h), Vector3(hx - AO_GAP, y0 + h * 0.5, hz - w * 0.5), -PI * 0.5, tex_corner, true)


## Градиентная текстура: тёмный край и прозрачный дальний конец. floor_strip: по вертикали (тёмный низ), иначе по горизонтали (тёмный левый край)
func _ao_tex(floor_strip: bool) -> GradientTexture2D:
	var g := Gradient.new()
	var dark := Color(AO_COLOR, AO_ALPHA)
	g.colors = PackedColorArray([dark, Color(AO_COLOR, AO_ALPHA * 0.35), Color(AO_COLOR, 0.0)])
	g.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 64
	t.height = 64
	t.fill_from = Vector2(0.0, 1.0) if floor_strip else Vector2(0.0, 0.0)
	t.fill_to = Vector2(0.0, 0.0) if floor_strip else Vector2(1.0, 0.0)
	return t


func _ao_quad(parent: Node, nm: String, size: Vector2, pos: Vector3, rot_y: float, tex: Texture2D, flip_h: bool) -> void:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = size
	mi.mesh = q
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = tex
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_receive_shadows = true
	if flip_h:
		m.uv1_scale = Vector3(-1.0, 1.0, 1.0)
		m.uv1_offset = Vector3(1.0, 0.0, 0.0)
	mi.material_override = m
	mi.name = nm
	mi.position = pos
	mi.rotation.y = rot_y
	mi.layers = _vis_layer()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


## Кусок стены между x0..x1 и y0..y1 на z = cz
func _slab(nm: String, x0: float, x1: float, y0: float, y1: float, cz: float) -> void:
	if x1 - x0 < 0.01 or y1 - y0 < 0.01:
		return
	_walls.append(_box(visuals, nm, Vector3(x1 - x0, y1 - y0, config.wall_thickness),
			Vector3((x0 + x1) * 0.5, (y0 + y1) * 0.5, cz), _wall_col,
			Global.active_layers(['room']), _shell_layer(), walls_cast_shadow))


# ==========================================
# Окно и небо
# ==========================================

## Рама с переплётом: отбрасывает тень на стол (в Observe)
func _build_window_frame() -> void:
	var c := config
	if c.window.is_empty():
		return
	var cz := -(c.size.z * 0.5 + c.wall_thickness * 0.5)
	var ox: float = c.window.x
	var ww: float = c.window.w
	var wh: float = c.window.h
	var s0: float = c.floor_y + c.window.sill
	var fb := 4.0
	var vis := _shell_layer()
	var col := Color(0.93, 0.93, 0.90)
	_walls.append(_box(visuals, "FrameTop", Vector3(ww, fb, 3.0), Vector3(ox, s0 + wh - fb * 0.5, cz), col, 0, vis, true))
	_walls.append(_box(visuals, "FrameBottom", Vector3(ww, fb, 3.0), Vector3(ox, s0 + fb * 0.5, cz), col, 0, vis, true))
	_walls.append(_box(visuals, "FrameLeft", Vector3(fb, wh, 3.0), Vector3(ox - ww * 0.5 + fb * 0.5, s0 + wh * 0.5, cz), col, 0, vis, true))
	_walls.append(_box(visuals, "FrameRight", Vector3(fb, wh, 3.0), Vector3(ox + ww * 0.5 - fb * 0.5, s0 + wh * 0.5, cz), col, 0, vis, true))
	_walls.append(_box(visuals, "MullionV", Vector3(3.0, wh, 2.0), Vector3(ox, s0 + wh * 0.5, cz), col, 0, vis, true))
	_walls.append(_box(visuals, "MullionH", Vector3(ww, 3.0, 2.0), Vector3(ox, s0 + wh * 0.55, cz), col, 0, vis, true))


## «Небо» за окном: плоскость с вертикальным градиентом, без освещения. Цвета меняет GFX (группа gfx_sky)
func _build_sky_card() -> void:
	var c := config
	if c.window.is_empty():
		return
	var mi := RoomDecor.make_sky_card(Vector2(700.0, 350.0), _vis_layer())
	mi.position = Vector3(c.window.x, c.floor_y + c.size.y * 0.35, -(c.size.z * 0.5) - 150.0)
	visuals.add_child(mi)


# ==========================================
# Хелперы
# ==========================================

## Только коллизия (без меша): внешний вид мебели строит RoomDecor
func _collider(parent: Node, nm: String, size: Vector3, center: Vector3, layers: int) -> void:
	var body := StaticBody3D.new()
	body.name = nm + "Collider"
	body.position = center
	body.collision_layer = layers
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	body.add_child(cs)
	parent.add_child(body)


## Потолочные лампы дневного света из RoomConfig.lamps. SpotLight3D вниз, тень только у ламп с shadow = true (тень дорогая).
## Свет живёт в RoomLights рядом с Room, а не внутри: кнопка «Комната» прячет стены, но не должна гасить свет над макетом
func _clear_room_lights() -> void:
	if is_instance_valid(_room_lights):
		if _room_lights.get_parent() == self:
			remove_child(_room_lights)
		_room_lights.queue_free()
	_room_lights = null


func _build_room_lights() -> void:
	if config.lamps.is_empty():
		return
	_room_lights = Node3D.new()
	_room_lights.name = "RoomLights"
	add_child(_room_lights)
	var i := 0
	for d in config.lamps:
		var l := SpotLight3D.new()
		l.name = "Lamp%d" % i
		var y: float = d.get("y", config.size.y - 6.0)
		l.position = Vector3(d.x, config.floor_y + y - 4.0, d.z)
		l.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		l.light_color = LAMP_COLOR
		l.light_energy = d.get("energy", 150.0)
		l.spot_range = LAMP_RANGE
		l.spot_angle = LAMP_ANGLE
		l.shadow_enabled = d.get("shadow", false)
		l.shadow_bias = 0.6            # как у лампы над столом (EnvironmentRoot): в см стандартные значения дают полосы на стенах
		l.shadow_normal_bias = 3.0
		l.light_size = LAMP_SOFT
		_room_lights.add_child(l)
		i += 1
	_room_lights.position.y = floor_offset()


func _lamp_height() -> float:
	if not is_inside_tree():
		return 120.0
	var l := get_tree().get_first_node_in_group(&"gfx_lamp") as Node3D
	return l.position.y if l else 120.0


func _vis_layer() -> int:
	return 1 << (Global.ROOM_VISUAL_LAYER - 1)


## Оболочка (стены, потолок, рама окна): отдельный visual layer, заполняющий свет SkyFill её не видит
func _shell_layer() -> int:
	return 1 << (Global.ROOM_SHELL_LAYER - 1)


func _mat(color: Color) -> StandardMaterial3D:
	if not _mats.has(color):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.9
		_mats[color] = m
	return _mats[color]


## Коробка: меш + (если body_layers != 0) StaticBody3D на этих слоях. vis_layers: visual layers меша
func _box(parent: Node, nm: String, size: Vector3, center: Vector3, color: Color,
		body_layers: int, vis_layers: int, shadow: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mat(color)
	mi.layers = vis_layers
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if body_layers == 0:
		mi.name = nm
		mi.position = center
		parent.add_child(mi)
		return mi
	var body := StaticBody3D.new()
	body.name = nm
	body.position = center
	body.collision_layer = body_layers
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	body.add_child(cs)
	mi.name = "Mesh"
	body.add_child(mi)
	parent.add_child(body)
	return mi
