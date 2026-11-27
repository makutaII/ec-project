class_name C_RoadControl extends ICapability

###########################
## Управляющий элемент дороги: стоп-секция, парковка, датчик (ATTN_28 §28.5, CS4a)
###########################
## Элементы это обычные куски дороги с компонентом C_RoadControl; вид задаёт RoadConfig.control (stop, parking, sensor, junction это CS4b).
##  - stop: катушка включена (enabled) и шина запитана: машина встаёт в точке остановки куска; выключена или нет питания: проезжает.
##    Включение по клику на лампу (рычаг на слое handles, в любом режиме, как рычаг стрелки). Питание: потребитель шины аксессуаров (PGM.bus),
##    перегрузка шины отключает элемент.
##  - parking: машина стоит до команды «поехали» (клик по лампе, release()), держит постоянный магнит, поэтому питание нужно только для
##    команды. После команды машина уезжает, следующая встаёт снова.
##  - sensor: occupied, пока на куске есть машина (CSM считает занятость в тике 20 Гц). Лампа красная занят, зелёная свободен.
## Связь по метке группы (group): у стоп-секции с группой катушка держит, только пока занят какой-либо датчик этой группы
## («занято, значит стоп»). Пустая группа: стоп-секция управляется только вручную.
## Лампа это маленький куб с подсветкой сбоку от дороги: стоп красная держит, зелёная пропускает, серая нет питания; парковка оранжевая
## (ярче, пока кто-то ждёт); датчик красная занят, зелёная свободен.
## Призрак и кусок в драге элементом не работают.

const STOP_WATTS := 1.8      # 150 мА x 12 В, катушка стоп-секции (Faller)
const SENSOR_WATTS := 0.1
## Где на куске машина встаёт: доля длины маршрута по ходу (0.5 это середина)
const POINT_FRAC := 0.5
const LAMP_SIZE := 0.8
const LAMP_OUT := 0.9        # ю от края полотна
const LEVER_SIZE := 1.4

const KIND_STOP := &"stop"
const KIND_PARKING := &"parking"
const KIND_SENSOR := &"sensor"

var kind: StringName = &"none"
## Катушка включена (стоп-секция)
var enabled := true
## Метка группы: связь датчика и стоп-секции
var group: StringName = &""
## Датчик занят
var occupied := false

var _released := {}          # парковка: машины, которым дали команду «поехали» (до выезда с куска)
var _inactive := false
var _loaded := false
var _lamp: MeshInstance3D
var _mat: StandardMaterial3D
var _lever: Area3D
var _lamp_code := -1


func on_entity_ready() -> void:
	var idc := entity.get_comp(C_Identity) as C_Identity
	var cfg := idc.object_config as RoadConfig if idc else null
	kind = cfg.control if cfg != null else &"none"
	if not _loaded and cfg != null:
		group = cfg.group
	_inactive = entity.has_comp(C_Ghost) or entity.has_comp(C_Drag)
	if kind == &"none" or kind == &"junction":
		return
	CSM.register_control(self)
	if not _inactive:
		PGM.bus.add_consumer(self)
	_build_indicator()
	_update_lamp()


func _exit_tree() -> void:
	if is_instance_valid(CSM):
		CSM.unregister_control(self)
	if is_instance_valid(PGM):
		PGM.bus.remove_consumer(self)


func on_component_added(t: Script) -> void:
	if t == C_Ghost or t == C_Drag:
		_set_inactive(true)


func on_component_removed(t: Script) -> void:
	_set_inactive((t != C_Drag and entity.has_comp(C_Drag)) or (t != C_Ghost and entity.has_comp(C_Ghost)))


func _set_inactive(v: bool) -> void:
	if v == _inactive:
		return
	_inactive = v
	if _inactive:
		PGM.bus.remove_consumer(self)
	elif kind != &"none":
		PGM.bus.add_consumer(self)
	if _lever != null:
		_lever.collision_layer = 0 if _inactive else Global.active_layers([&"handles"])
	_update_lamp()


# ==========================================
# Что умеет элемент для машин
# ==========================================

## Элемент может держать машину (стоп-секция или парковка, не призрак)
func can_hold() -> bool:
	return not _inactive and (kind == KIND_STOP or kind == KIND_PARKING)


## Держит ли элемент эту машину сейчас
func holds_for(v: C_RoadVehicle) -> bool:
	if not can_hold():
		return false
	if kind == KIND_STOP:
		return enabled and PGM.bus_powered() and (group.is_empty() or CSM.group_occupied(group))
	return not _released.has(v)


## Точка остановки на маршруте состояния st: dist вдоль маршрута (машина встаёт центром кузова)
func stop_point(st: Dictionary) -> float:
	var pc := (st.track as Entity).get_comp(C_Path) as C_Path
	if pc == null or pc.curve_of(int(st.route)) == null:
		return 0.0
	var length := pc.curve_of(int(st.route)).get_baked_length()
	return length * (POINT_FRAC if float(st.dir) > 0.0 else 1.0 - POINT_FRAC)


## Мощность на шине аксессуаров, Вт (AccessoryBus.step вызывает при load_for_lights)
func bus_watts() -> float:
	if _inactive:
		return 0.0
	if kind == KIND_STOP:
		return STOP_WATTS if enabled else 0.0
	if kind == KIND_SENSOR:
		return SENSOR_WATTS
	return 0.0


# ==========================================
# Команды игрока и автоматика
# ==========================================

## Стоп-секция: включить или выключить катушку
func set_enabled(on: bool) -> void:
	if on == enabled:
		return
	enabled = on
	_update_lamp()
	entity.send_event("on_road_control_changed", {"kind": kind, "enabled": enabled})


func toggle() -> void:
	set_enabled(not enabled)


## Парковка: команда «поехали» всем машинам, которые здесь стоят или подъезжают. Нужна шина (импульс катушки). false: не приняли
func release() -> bool:
	if kind != KIND_PARKING or _inactive or not PGM.bus_powered():
		return false
	for v in CSM.get_vehicles():
		if v.hold_control == self:
			_released[v] = true
	_update_lamp()
	entity.send_event("on_road_control_changed", {"kind": kind, "released": true})
	return true


func set_group(g: StringName) -> void:
	group = g
	_update_lamp()


## Клик по лампе (SelectTool шлёт, когда луч попал в слой handles и у сущности есть этот компонент)
func on_lever_pressed(data: Dictionary) -> void:
	var col := data.get("collider") as Node
	if col == null or not col.has_meta(&"road_lever") or not entity.is_ancestor_of(col):
		return
	data["consumed"] = true
	if kind == KIND_STOP:
		toggle()
	elif kind == KIND_PARKING:
		release()


## Тик CSM (20 Гц). on_track: ключи это instance_id кусков дороги, на которых сейчас есть машины
func tick(on_track: Dictionary) -> void:
	if _inactive:
		return
	if kind == KIND_SENSOR:
		var occ := on_track.has(entity.get_instance_id())
		if occ != occupied:
			occupied = occ
			entity.send_event("on_road_sensor_changed", {"occupied": occupied})
			CSM.sensor_changed.emit(self, occupied)
	elif kind == KIND_PARKING:
		for v in _released.keys():
			if not is_instance_valid(v) or not v.state.has("track") or v.state.track != entity:
				_released.erase(v)
	_update_lamp()


# ==========================================
# Лампа
# ==========================================

func _build_indicator() -> void:
	var path := get_comp(C_Path) as C_Path
	var side := (path.bed_half_width() if path != null else 2.5) + LAMP_OUT
	var y := (path.head_height() if path != null else 0.3) + LAMP_SIZE * 0.5
	_mat = StandardMaterial3D.new()
	_mat.emission_enabled = true
	_mat.roughness = 0.4
	var bm := BoxMesh.new()
	bm.size = Vector3(LAMP_SIZE, LAMP_SIZE, LAMP_SIZE)
	_lamp = MeshInstance3D.new()
	_lamp.name = "ControlLamp"
	_lamp.mesh = bm
	_lamp.material_override = _mat
	_lamp.position = Vector3(side, y, 0.0)
	entity.add_child(_lamp)
	if kind == KIND_STOP or kind == KIND_PARKING:
		_lever = Area3D.new()
		_lever.name = "ControlLever"
		_lever.set_meta(&"road_lever", true)
		_lever.collision_layer = 0 if _inactive else Global.active_layers([&"handles"])
		_lever.collision_mask = 0
		_lever.monitoring = false
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(LEVER_SIZE, LEVER_SIZE, LEVER_SIZE)
		shape.shape = box
		_lever.add_child(shape)
		_lever.position = _lamp.position
		entity.add_child(_lever)


## 0 нет питания, 1 красная, 2 зелёная, 3 оранжевая, 4 яркая оранжевая
func _compute_lamp_code() -> int:
	if _inactive:
		return 0
	match kind:
		KIND_STOP:
			if not PGM.bus_powered():
				return 0
			return 1 if (enabled and (group.is_empty() or CSM.group_occupied(group))) else 2
		KIND_PARKING:
			for v in CSM.get_vehicles():
				if v.hold_control == self and v.mode == C_RoadVehicle.Mode.HALTED:
					return 4
			return 3
		KIND_SENSOR:
			return 1 if occupied else 2
	return 0


func _update_lamp() -> void:
	if _mat == null:
		return
	var code := _compute_lamp_code()
	if code == _lamp_code:
		return
	_lamp_code = code
	var c := Color(0.3, 0.3, 0.32)
	var energy := 0.0
	match code:
		1:
			c = Color(1.0, 0.15, 0.1)
			energy = 1.6
		2:
			c = Color(0.1, 0.9, 0.25)
			energy = 1.6
		3:
			c = Color(1.0, 0.55, 0.1)
			energy = 0.5
		4:
			c = Color(1.0, 0.55, 0.1)
			energy = 1.8
	_mat.albedo_color = c
	_mat.emission = c
	_mat.emission_energy_multiplier = energy


# ==========================================
# Сейв
# ==========================================

func save_data() -> Dictionary:
	return {
		'comp_path': get_script().resource_path,
		'comp_name': get_script().resource_path.get_file().get_basename(),
		'enabled': enabled,
		'group': String(group),
	}


func load_data(data: Dictionary) -> void:
	_loaded = true
	enabled = bool(data.get("enabled", true))
	group = StringName(data.get("group", ""))
	_lamp_code = -1
	_update_lamp()
