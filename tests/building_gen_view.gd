extends Node3D

# XX claude-library L7 (новый файл)
## Просмотр генератора зданий (ATTN_22 §22.7.6, шаг L7): четыре здания разных форм рядом с house_01 для масштаба.
## Запуск: открыть tests/building_gen_view.tscn и нажать F6. Автотестов тут нет (они в building_gen_test.tscn).
## Камера: ЛКМ вращать, колесо зум, Shift+ЛКМ или СКМ сдвиг, F вписать. В Output строки бюджета: вершины и треугольники.

const SPACING := 18.0

var _cam: Camera3D
var _yaw := 25.0
var _pitch := -28.0
var _dist := 55.0
var _target := Vector3(0.0, 4.0, 0.0)
var _drag := false


func _ready() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.62, 0.7)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.75, 0.78, 0.85)
	env.environment.ambient_light_energy = 0.6
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -35.0, 0.0)
	sun.shadow_enabled = true
	add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200.0, 80.0)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.36, 0.42, 0.3)
	ground.material_override = gm
	add_child(ground)
	_cam = Camera3D.new()
	_cam.far = 400.0
	add_child(_cam)

	var factory := EntityFactory.new()
	add_child(factory)
	var specs: Array[Dictionary] = [
		{"width": 10.0, "depth": 7.0, "floors": 2, "style": "brick", "seed": 1},
		{"shape": "l", "width": 14.0, "depth": 10.0, "notch_w": 5.0, "notch_d": 4.0, "floors": 2, "style": "plaster", "seed": 11},
		{"width": 8.0, "depth": 6.0, "floors": 4, "roof": "flat", "style": "stone", "seed": 5},
		{"width": 6.0, "depth": 5.0, "floors": 1, "pitch": 0.8, "overhang": 0.6, "style": "plaster", "seed": 77},
	]
	var setting := load("res://data/buildings/objects/building_gen.tres") as EntitySetting
	var x := -SPACING * 2.0
	for d in specs:
		var spec := BuildingSpec.from_dict(d)
		var e := factory.create_from_setting(setting, &"", {"building": spec.to_dict()})
		add_child(e)
		e.position = Vector3(x, 0.0, 0.0)
		var gen := e.get_comp(C_BuildingGen) as C_BuildingGen
		if gen != null:
			print("здание %s: вершин %d, треугольников %d, окон %d" % [spec.style, gen.stats["vertices"], gen.stats["triangles"], gen.layout.openings.size()])
		x += SPACING
	var house := load("res://data/buildings/objects/house_01.tres") as EntitySetting
	if house != null:
		var h := factory.create_from_setting(house)
		add_child(h)
		h.position = Vector3(x, 0.0, 0.0)
	_update_cam()


func _update_cam() -> void:
	var basis := Basis.from_euler(Vector3(deg_to_rad(_pitch), deg_to_rad(_yaw), 0.0))
	_cam.global_position = _target + basis * Vector3(0.0, 0.0, _dist)
	_cam.look_at(_target, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null:
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_drag = mb.pressed
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(5.0, _dist * 0.9)
			_update_cam()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(250.0, _dist * 1.1)
			_update_cam()
	var mm := event as InputEventMouseMotion
	if mm != null and _drag:
		if Input.is_key_pressed(KEY_SHIFT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			var right := _cam.global_transform.basis.x
			var up := _cam.global_transform.basis.y
			_target += (-right * mm.relative.x + up * mm.relative.y) * _dist * 0.002
		else:
			_yaw -= mm.relative.x * 0.3
			_pitch = clampf(_pitch - mm.relative.y * 0.3, -85.0, 10.0)
		_update_cam()
	var k := event as InputEventKey
	if k != null and k.pressed and not k.echo and k.keycode == KEY_F:
		_target = Vector3(0.0, 4.0, 0.0)
		_dist = 55.0
		_update_cam()
