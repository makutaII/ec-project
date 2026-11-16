extends Node

## Проверка Actuator.ANIM (0_ATTN_24 §24.6, шаг S3): механизм ставит позы узлов по состоянию 0..1 из анимации модели.
## Запуск: открыть tests/mech_anim_test.tscn и нажать F6. Итог в Output: строки PASS/FAIL и «Mech anim: n/m».
## Модель собирается кодом: корень, две детали и AnimationPlayer с двумя анимациями (как после экспорта из Blender:
## первый ключ не в нуле). Сущность и InfoPanel не нужны: проверяются Mech и _setup_anim напрямую.

var _ok := 0
var _all := 0


func _ready() -> void:
	var root := Node3D.new()
	add_child(root)
	var part_a := Node3D.new()
	part_a.name = "PartA"
	root.add_child(part_a)
	var part_b := Node3D.new()
	part_b.name = "PartB"
	root.add_child(part_b)

	# mech_a: PartA сдвигается на 3 по Z, ключи на 0.5 и 2.5 с (не с нуля)
	var anim_a := Animation.new()
	anim_a.length = 2.5
	var ta := anim_a.add_track(Animation.TYPE_POSITION_3D)
	anim_a.track_set_path(ta, NodePath("PartA"))
	anim_a.position_track_insert_key(ta, 0.5, Vector3.ZERO)
	anim_a.position_track_insert_key(ta, 2.5, Vector3(0, 0, 3))
	# mech_b: PartB поворачивается на 90° вокруг Y, ключи на 0.25 и 1.25 с
	var anim_b := Animation.new()
	anim_b.length = 1.25
	var tb := anim_b.add_track(Animation.TYPE_ROTATION_3D)
	anim_b.track_set_path(tb, NodePath("PartB"))
	anim_b.rotation_track_insert_key(tb, 0.25, Quaternion.IDENTITY)
	anim_b.rotation_track_insert_key(tb, 1.25, Quaternion(Vector3.UP, PI / 2.0))
	# mech_c: постоянная дорожка позиции и поворот на 90° у PartA (как у экспорта из Blender: ключи покоя в соседнем канале)
	var anim_c := Animation.new()
	anim_c.length = 1.0
	var tc1 := anim_c.add_track(Animation.TYPE_POSITION_3D)
	anim_c.track_set_path(tc1, NodePath("PartA"))
	anim_c.position_track_insert_key(tc1, 0.0, Vector3(1, 2, 3))
	anim_c.position_track_insert_key(tc1, 1.0, Vector3(1, 2, 3))
	var tc2 := anim_c.add_track(Animation.TYPE_ROTATION_3D)
	anim_c.track_set_path(tc2, NodePath("PartA"))
	anim_c.rotation_track_insert_key(tc2, 0.0, Quaternion.IDENTITY)
	anim_c.rotation_track_insert_key(tc2, 1.0, Quaternion(Vector3.UP, PI / 2.0))
	var lib := AnimationLibrary.new()
	lib.add_animation(&"mech_c", anim_c)
	lib.add_animation(&"mech_a", anim_a)
	lib.add_animation(&"mech_b", anim_b)
	var src := AnimationPlayer.new()
	root.add_child(src)
	src.root_node = NodePath("..")
	src.add_animation_library(&"", lib)

	var comp := C_Mechanisms.new()
	var vis := C_Visual.new()
	vis.instance = root
	var ma := _mech(&"a")
	var mb := _mech(&"b")
	comp._setup_anim(ma, vis)
	comp._setup_anim(mb, vis)

	_check("ANIM: обе анимации найдены", ma.found() and mb.found())
	_check("ANIM: состояние 0 и 1 это первый и последний ключ (0.5 и 2.5 с)", is_equal_approx(ma.anim_t0, 0.5) and is_equal_approx(ma.anim_t1, 2.5))
	_check("ANIM: плеер модели один, свои плееры не создаются", root.find_children("*", "AnimationPlayer", true, false).size() == 1)

	ma.t = 0.0
	mb.t = 0.0
	ma.apply()
	mb.apply()
	_check("ANIM: поза покоя (t = 0) это первый ключ", part_a.position.is_equal_approx(Vector3.ZERO) and part_b.basis.is_equal_approx(Basis.IDENTITY))

	ma.t = 1.0
	mb.t = 1.0
	ma.apply()
	mb.apply()
	_check("ANIM: t = 1, оба механизма в рабочем положении одновременно",
		part_a.position.is_equal_approx(Vector3(0, 0, 3)) and part_b.basis.x.is_equal_approx(Vector3(0, 0, -1)))

	ma.t = 0.5
	ma.apply()
	_check("ANIM: t = 0.5, середина хода (smoothstep даёт 0.5), второй механизм не сдвинулся",
		absf(part_a.position.z - 1.5) < 0.001 and part_b.basis.x.is_equal_approx(Vector3(0, 0, -1)))

	ma.t = 0.0
	mb.t = 1.0
	ma.apply()
	mb.apply()
	_check("ANIM: механизмы независимы (A в покое, B открыт)", part_a.position.is_equal_approx(Vector3.ZERO) and part_b.basis.x.is_equal_approx(Vector3(0, 0, -1)))

	var mc := _mech(&"c")
	comp._setup_anim(mc, vis)
	_check("ANIM: постоянная дорожка пропущена, остаётся только поворот",
		mc.found() and mc.anim_tracks.size() == 1 and mc.anim_tracks[0].kind == Animation.TYPE_ROTATION_3D)
	_check("ANIM: два механизма на одном узле дают предупреждение, независимые нет",
		C_Mechanisms.find_node_conflicts([ma, mc]).size() == 1 and C_Mechanisms.find_node_conflicts([ma, mb]).is_empty())
	ma.t = 1.0
	ma.apply()
	var pose_ok := ma.pose_error() < 0.001
	part_a.position = Vector3(5, 0, 0)
	_check("ANIM: pose_error замечает изменение позы снаружи", pose_ok and ma.pose_error() > 0.01)

	var missing := _mech(&"nope")
	comp._setup_anim(missing, vis)
	_check("ANIM: нет такой анимации, механизм не найден и apply не падает", not missing.found())
	missing.apply()

	_check("ANIM: старые значения enum не сдвинулись", MechanismConfig.Actuator.SLIDE == 0 and MechanismConfig.Actuator.ROTATE == 1
		and MechanismConfig.Actuator.ANIM == 6)

	print("Mech anim: %d/%d" % [_ok, _all])
	get_tree().quit(0 if _ok == _all else 1)


func _mech(id: StringName) -> C_Mechanisms.Mech:
	var cfg := MechanismConfig.new()
	cfg.id = id
	cfg.actuator = MechanismConfig.Actuator.ANIM
	cfg.anim_name = StringName("mech_%s" % id)
	var m := C_Mechanisms.Mech.new()
	m.cfg = cfg
	return m


func _check(title: String, cond: bool) -> void:
	_all += 1
	if cond:
		_ok += 1
		print("PASS ", title)
	else:
		print("FAIL ", title)
