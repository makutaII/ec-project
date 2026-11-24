class_name RoomBuilder extends Node3D

########################
## RoomRoot. Строит комнату из RoomConfig под собой. НЕ в EntitiesRoot и не сохраняется (TDD §14.1).
########################
## Комната берётся из сцены RoomConfig.scene (корень RoomRoot, модель из Blender): RoomRoot настраивает слои, свет и роли .glb.
## Процедурной комнаты (greybox, RoomDecor, RoomAttic) больше нет (ATTN_25 RM9b). Здесь же подмакетник.
## Подмакетник (Table): плиту строят секции-Entity (C_TableSection, слой ground, ATTN_23 T1), здесь только ножки на room.
## Он не скрывается кнопкой «Комната».
## Всё остальное (Room) на слое room (физика, коллайдеры из сцены) и на visual layer Global.ROOM_VISUAL_LAYER.
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

var visuals: Node3D    # корень сцены комнаты: пол, стены, потолок, мебель
var ceiling: Node3D
var _ceiling_mesh: MeshInstance3D   # плита потолка: скрытая в Observe, она всё равно отбрасывает тень (закрывает солнце сверху)
var table: Node3D
var _layout_dirty := false
var _room_lights: Node3D   # лампы сцены (ветка Lights): не часть visuals, чтобы скрытие комнаты (F3 → Toggles) не гасило свет

var _mats := {}   # материалы ножек стола (_mat)
var _walls: Array[MeshInstance3D] = []   # стены, рама, шторы и подоконник: тень только в Observe
var _controls := RoomControlRegistry.new()   # управляемые объекты активной комнаты (ATTN_25 §25.6)
var _root: RoomRoot   # корень сцены комнаты (RoomConfig.scene), null у стенда без сцены
var _room_visible := true
var _ceiling_visible := false
var _walls_shadow_now := false

const COL_TABLE_LEG := Color(0.45, 0.36, 0.28)


func _ready() -> void:
	if config == null:
		config = RoomCatalog.make(RoomCatalog.DEFAULT_ID)   # комната по умолчанию: детская из сцены
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
	if _root:
		_root.set_lamp_glow(GFX.is_lamp_on())
	_apply_detail()


func _on_lamp_changed(on: bool) -> void:
	if _root:
		_root.set_lamp_glow(on)


func _apply_detail() -> void:
	var q: QualityPreset = GFX.get_quality()
	var lod := q.room_detail_lod if q else 1
	if _root:
		_root.set_detail(lod)


## Потолочные лампы комнаты (ветка Lights сцены). null: ламп нет. Для корректора графики (GfxLab)
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


## Пересобрать всё (после смены config): стол и комнату
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


func _build_room() -> void:
	_walls.clear()
	ceiling = null
	_ceiling_mesh = null
	_root = null
	_controls = RoomControlRegistry.new()
	visuals = Node3D.new()
	visuals.name = "Room"
	add_child(visuals)
	_clear_room_lights()
	if config.scene:
		_build_from_scene()
	elif config.shape != &"none":
		push_warning("RoomBuilder: у комнаты %s нет сцены (RoomConfig.scene), строится только стол" % config.id)
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
	var r := RoomRoot.wrap(inst)   # чужой Node3D-корень (унаследованная от .glb сцена) заворачивается в RoomRoot
	if r == null:
		push_warning("RoomBuilder: корень сцены комнаты %s не Node3D, слои, потолок и лампы не настроены" % config.id)
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


## Управляемые объекты активной комнаты (пустой, если комнаты нет). Читает Observe → Light
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
## До _ready только подменяет паспорт (стартовую сборку сделает _ready)
## Внутренний метод: снаружи звать request_room
func switch_room(id: StringName) -> void:
	if Global.fast_debug:
		return
	if config != null and config.id == id:
		return
	config = RoomCatalog.make(id)
	if not is_node_ready() or not is_in_group(&"room_root"):
		return
	build()
	room_changed.emit(config.id)
	GFX.set_state(GFX.get_state())   # небо и лампа пересобранной комнаты


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
	# XX claude-wire W2: опоры ещё и на слое underside (лучи монтажа под столом), подрамник из LayoutConfig.apron
	var room_layer := Global.active_layers(['room', 'underside'])
	for part in TableSupports.parts(int(LYM.config.support), LYM.footprint(), LYM.config.height, LYM.plate_thickness(),
			config.table_leg, config, LYM.config.apron):
		var mi := _box(table, part["name"], part["size"], part["center"], COL_TABLE_LEG, room_layer, 1, true)
		if mi != null:
			var b := part["basis"] as Basis
			if not b.is_equal_approx(Basis.IDENTITY):
				var body := mi.get_parent() as Node3D
				var tf := body.transform
				tf.basis = b
				body.transform = tf


## Свет предыдущей комнаты (лежит рядом с Room, а не внутри: кнопка «Комната» прячет стены, но не гасит свет над макетом)
func _clear_room_lights() -> void:
	if is_instance_valid(_room_lights):
		if _room_lights.get_parent() == self:
			remove_child(_room_lights)
		_room_lights.queue_free()
	_room_lights = null


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
