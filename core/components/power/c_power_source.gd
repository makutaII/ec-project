class_name C_PowerSource extends C_Visual

#####################
## 3D-пульт питания (ATTN_10 §10.5.5, D4)
#####################
## Оборачивает PowerSource (D2) в сущность на столе. Корпус, ручки и кнопки строятся кодом из примитивов
## (боксы и цилиндры), красота позже. Ручка вывода это вращение мышью вокруг оси ручки (как круглая ручка 2D):
## SelectTool при нажатии шлёт `on_lever_pressed`, затем 10 раз в кадр `on_handle_drag` с лучом мыши.
## Кнопки: аварийный стоп источника, «Сеть» (PGM.mains), «Сброс» защиты. Лампы: сеть, перегрузка, КЗ.
## Клеммы PowerTerminal на лицевой грани: по одной на вывод (метка вывода идёт из PowerSource).
## Модель берётся из PowerModels (`standard`: 1 вывод, `dual`: A и B).

const H := 1.6        # высота корпуса
const DEPTH := 5.0
const KNOB_R := 0.9
const ANGLE_RANGE := 135.0   # градусов от нуля до ±100 %

var model: StringName = &"standard"
var source: PowerSource

var _body: StaticBody3D
var _knobs: Array[Node3D] = []         # поворотная часть ручки каждого вывода
var _labels: Array[Label3D] = []
var _terms: Array[PowerTerminal] = []
var _lamps: Dictionary = {}            # "mains" / "over" / "short" -> MeshInstance3D
var _estop_mesh: MeshInstance3D
var _controls: Dictionary = {}         # StaticBody3D -> ["knob", i] | ["estop"] | ["mains"] | ["reset"]
var _drag_i := -1
var _drag_a0 := 0.0
var _drag_v0 := 0


func on_added() -> void:
	name = "C_PowerSource"
	add_to_group(&"power_device")
	_build()
	_collect_meshes()


func on_entity_ready() -> void:
	if entity.has_comp(C_Ghost):
		return
	_register()


func _register() -> void:
	if source != null:
		return
	source = PGM.register_source(model, self)
	PGM.solver_stepped.connect(_refresh_display)
	PGM.power_updated.connect(_on_power_updated)
	PGM.state_loaded.connect(_refresh_display)
	PGM.state_reset.connect(_refresh_display)
	sync_terminals()
	_refresh_display()


## Призрак стройки не источник: снимаем источник и клеммы. Реальный объект создаётся фабрикой заново
func on_component_added(type: Script) -> void:
	super(type)
	if type == C_Ghost:
		_release_source()
		for t in _terms:
			t.collision_layer = 0
			t.remove_from_group(&"power_terminal")


func _release_source() -> void:
	if source == null:
		return
	if PGM.solver_stepped.is_connected(_refresh_display):
		PGM.solver_stepped.disconnect(_refresh_display)
	if PGM.power_updated.is_connected(_on_power_updated):
		PGM.power_updated.disconnect(_on_power_updated)
	if PGM.state_loaded.is_connected(_refresh_display):
		PGM.state_loaded.disconnect(_refresh_display)
	if PGM.state_reset.is_connected(_refresh_display):
		PGM.state_reset.disconnect(_refresh_display)
	PGM.remove_source(source)
	source = null


func _exit_tree() -> void:
	# Пульт удален со стола: источник исчезает вместе с ним, провода удалятся сами (клеммы освободятся)
	if entity != null and entity.is_queued_for_deletion():
		_release_source()


# ------ СБОРКА КОРПУСА ------

func _build() -> void:
	var md := PowerModels.get_model(model)
	var n: int = int(md.outputs)
	var width := 3.0 + 3.0 * n
	instance = Node3D.new()
	instance.name = "PowerDevice"
	entity.add_child(instance)

	_body = StaticBody3D.new()
	_body.name = "Body"
	_body.collision_layer = Global.active_layers(["power"])
	_body.collision_mask = 0
	instance.add_child(_body)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(width, H, DEPTH)
	shape.shape = box
	shape.position = Vector3(0, H * 0.5, 0)
	_body.add_child(shape)
	_add_box(_body, Vector3(width, H, DEPTH), Vector3(0, H * 0.5, 0), Color(0.22, 0.24, 0.28))

	var x0 := -width * 0.5 + 1.8
	for i in n:
		var x := x0 + 3.0 * i
		_add_knob(i, Vector3(x, H, -0.4))
		var term := PowerTerminal.create(instance, entity, PowerTerminal.Kind.TRACK, PowerTerminal.Role.SRC, StringName("out_%d" % i), Vector3(x, 0.8, DEPTH * 0.5 + 0.2))
		_terms.append(term)
		var lab := Label3D.new()
		lab.pixel_size = 0.02
		lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lab.no_depth_test = true
		lab.position = Vector3(x, H + 1.6, -0.4)
		instance.add_child(lab)
		_labels.append(lab)

	# Кнопки по правому краю: стоп, сеть, сброс. Лампы рядом
	var bx := width * 0.5 - 0.7
	_estop_mesh = _add_button(["estop"], Vector3(bx, H, DEPTH * 0.5 - 0.9), Color(0.8, 0.1, 0.1))
	_add_button(["mains"], Vector3(bx, H, DEPTH * 0.5 - 2.0), Color(0.2, 0.6, 0.2))
	_add_button(["reset"], Vector3(bx, H, DEPTH * 0.5 - 3.1), Color(0.2, 0.4, 0.85))
	_lamps["mains"] = _add_lamp(Vector3(bx - 1.1, H, DEPTH * 0.5 - 2.0))
	_lamps["over"] = _add_lamp(Vector3(bx - 1.1, H, DEPTH * 0.5 - 3.1))
	_lamps["short"] = _add_lamp(Vector3(bx - 1.1, H, DEPTH * 0.5 - 0.9))


func _add_box(parent: Node3D, size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _add_cyl(parent: Node3D, r: float, h: float, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = r
	m.bottom_radius = r
	m.height = h
	mi.mesh = m
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mi.material_override = mat
	parent.add_child(mi)
	return mi


## Область управления на слое handles: по ней SelectTool находит рычаг
func _make_control(info: Array, pos: Vector3, radius: float, height: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = Global.active_layers(["handles"])
	body.collision_mask = 0
	body.position = pos
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = height
	cs.shape = cyl
	cs.position = Vector3(0, height * 0.5, 0)
	body.add_child(cs)
	instance.add_child(body)
	_controls[body] = info
	return body


func _add_knob(i: int, pos: Vector3) -> void:
	var ctl := _make_control(["knob", i], pos, KNOB_R, 0.7)
	var turn := Node3D.new()
	ctl.add_child(turn)
	_add_cyl(turn, KNOB_R, 0.6, Vector3(0, 0.3, 0), Color(0.75, 0.75, 0.78))
	_add_box(turn, Vector3(0.15, 0.1, KNOB_R), Vector3(0, 0.65, -KNOB_R * 0.5), Color(0.9, 0.1, 0.1))   # указатель
	_knobs.append(turn)


func _add_button(info: Array, pos: Vector3, color: Color) -> MeshInstance3D:
	var ctl := _make_control(info, pos, 0.4, 0.4)
	return _add_cyl(ctl, 0.4, 0.4, Vector3(0, 0.2, 0), color)


func _add_lamp(pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = 0.25
	m.height = 0.5
	mi.mesh = m
	mi.position = pos + Vector3(0, 0.1, 0)
	instance.add_child(mi)
	return mi


# ------ ВЗАИМОДЕЙСТВИЕ ------

## Слой выбора: выбранный и призрак лежат на ghost, остальные на power (как у вагона и трака)
func on_select_layer(data: Dictionary) -> void:
	if _body == null:
		return
	_body.collision_layer = Global.active_layers(["ghost"]) if data.get("enabled", false) else Global.active_layers(["power"])


## Нажатие на элемент управления (SelectTool._try_press_lever)
func on_lever_pressed(data: Dictionary) -> void:
	if source == null:
		return
	var info = _controls.get(data.get("collider"), null)
	if info == null:
		return
	match info[0]:
		"knob":
			_drag_i = int(info[1])
			_drag_v0 = source.outputs[_drag_i].command
			_drag_a0 = _ray_angle(data.get("ray", {}), _drag_i)
			data.consumed = true
			data.drag = true
		"estop":
			PGM.emergency_stop(not source.estop, source)
			data.consumed = true
		"mains":
			PGM.set_mains(not PGM.mains.on)
			data.consumed = true
		"reset":
			PGM.reset_protection(source)
			data.consumed = true
	_refresh_display()


## Тянем ручку: луч мыши пересекает плоскость ручки, угол вокруг оси это команда
func on_handle_drag(data: Dictionary) -> void:
	if _drag_i < 0 or source == null:
		return
	var delta := wrapf(_ray_angle(data, _drag_i) - _drag_a0, -180.0, 180.0)
	var v := clampi(roundi(_drag_v0 + delta * 100.0 / ANGLE_RANGE), -100, 100)
	var out := source.outputs[_drag_i]
	if v != out.command:
		PGM.set_command(out.label, v, source)
		source.selected = out.label
		_refresh_display()


func on_handle_released(_data: Dictionary) -> void:
	_drag_i = -1


## Угол луча в плоскости ручки i, градусов от «вперёд» корпуса
func _ray_angle(ray: Dictionary, i: int) -> float:
	if ray.is_empty() or not ray.has("from"):
		return 0.0
	var knob := _knobs[i].get_parent() as Node3D
	var center := knob.global_position
	var up := instance.global_basis.y
	var hit = Plane(up, center.dot(up)).intersects_ray(ray["from"], ray["dir"])
	if hit == null:
		return _drag_a0
	var v: Vector3 = hit - center
	var right := instance.global_basis.x
	var fwd := -instance.global_basis.z
	return rad_to_deg(atan2(v.dot(right), v.dot(fwd)))


# ------ ВИД ------

func _on_power_updated(_label: int, _v: float) -> void:
	_refresh_display()


func _refresh_display() -> void:
	if source == null or not is_instance_valid(instance):
		return
	for i in source.outputs.size():
		var o := source.outputs[i]
		_knobs[i].rotation_degrees.y = -o.command * ANGLE_RANGE / 100.0
		var text := "Вывод %d%s\n%+d%%" % [o.label, (" " + o.suffix) if o.suffix != "" else "", o.command]
		if o.tripped:
			text += "  ⚡ " + o.state_text()
		elif PGM.get_power(o.label) != 0.0:
			text += "  %.2f А" % o.current
		_labels[i].text = text
		_labels[i].modulate = Color(1, 0.3, 0.25) if o.tripped else (Color(1, 0.8, 0.2) if o.state == PowerOutput.State.OVERLOAD else Color.WHITE)
	var over := false
	var short := false
	for o in source.outputs:
		if o.tripped:
			if o.trip_reason == "overload":
				over = true
			else:
				short = true
		elif o.state == PowerOutput.State.OVERLOAD:
			over = true
	_set_lamp("mains", PGM.mains.on, Color(0.1, 1.0, 0.2))
	_set_lamp("over", over, Color(1.0, 0.75, 0.1))
	_set_lamp("short", short, Color(1.0, 0.15, 0.1))
	_set_color(_estop_mesh, Color(1.0, 0.25, 0.25) if source.estop else Color(0.5, 0.1, 0.1))


func _set_lamp(key: String, on: bool, color: Color) -> void:
	_set_color(_lamps[key], color if on else Color(0.15, 0.15, 0.15))


func _set_color(mi: MeshInstance3D, color: Color) -> void:
	var mat := mi.material_override as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		mi.material_override = mat
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.5


## Метки на клеммах по выводам источника (PGM зовёт перед расчётом проводки; метки меняются при загрузке)
func sync_terminals() -> void:
	if source == null:
		return
	for i in _terms.size():
		if i < source.outputs.size():
			_terms[i].output_label = source.outputs[i].label


## Автопроводка (D4): провод от каждого свободного вывода к клипам, у которых этот номер задан меткой
## (виртуальная проводка превращается в физическую). Возвращает число созданных проводов
func autowire(parent: Node) -> int:
	if source == null:
		return 0
	sync_terminals()
	var made := 0
	for i in _terms.size():
		var t := _terms[i]
		for clip in PGM.active_clips:
			if not is_instance_valid(clip) or clip.terminal == null or not is_instance_valid(clip.terminal):
				continue
			if clip.net_id != t.output_label or clip.wired or not clip.terminal.is_free():
				continue
			# XX claude-wire W7: провод лежит на поверхностях, под столом через ввод и по нижней полке (AutoWire), не дугой по воздуху
			if C_Wire.create_wire(parent, t, clip.terminal, AutoWire.points(t, clip.terminal, made)) != null:
				made += 1
	return made


# ------ СЕЙВ ------

func save_data() -> Dictionary:
	if source == null:
		return {}
	return {"model": String(model), "source": source.save_data()}


func load_data(d: Dictionary) -> void:
	var sd: Dictionary = d.get("source", {})
	if sd.is_empty() or source == null:
		return
	# Источнику возвращаем прежние номер и метки: PGM.load_state узнает его по id и подставит команды и защиту
	var labels: Array = []
	for od: Dictionary in sd.get("outputs", []):
		labels.append(int(od.get("label", 0)))
	PGM.restore_source_identity(source, int(sd.get("id", source.id)), labels)
	sync_terminals()
