extends Node3D

# XX claude-library (новый файл)
## Проверка: маски (ATTN_22 §22.7.2.1, шаг C2.5): скотч (мазок в карту маски), трафарет (картинка из двух «цветов»: рисунок
## и фон, один накрывает; если у картинки есть прозрачность, рисунок это непрозрачная часть), открытие и очистка маски,
## защита от краски, ластика и декали. Нужен рендер (слой краски и маска это SubViewport).
## Запуск: открыть tests/library_paint_mask_test.tscn и нажать F6.
## Итог в Output: строки PASS/FAIL и «Library paint mask: n/m».

const RES := 64
const N := Vector3(0, 0, 1)

var _ok := 0
var _all := 0


func _ready() -> void:
	await _test()
	print("Library paint mask: %d/%d" % [_ok, _all])
	get_tree().quit(0 if _ok == _all else 1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Квадрат 1x1 лицом к +Z, UV2 на весь атлас: пиксель слоя (px, py) это точка (px / 64 - 0.5, 0.5 - py / 64)
func _quad() -> MeshInstance3D:
	var arrays := QuadMesh.new().get_mesh_arrays()
	var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv2 := PackedVector2Array()
	for v in vs:
		uv2.append(Vector2(v.x + 0.5, 0.5 - v.y))
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


func _a(img: Image, x: int, y: int) -> float:
	return img.get_pixel(x, y).a


func _reset(eng: PaintEngine) -> void:
	eng.clear()
	eng.clear_mask()
	await _frames(6)


## Штамп маски (скотч): круг радиуса r в точке at; erase открывает
func _tape(eng: PaintEngine, at: Vector3, r: float, erase := false) -> void:
	eng.begin_stroke()
	eng.stamp(at, N, r, Color.WHITE, 1.0, 0.99, erase, {"mask": true})
	eng.end_stroke()


## Трафарет: картинка id как маска в точке at радиуса r; ink: накрывает рисунок (иначе фон)
func _stencil(eng: PaintEngine, id: String, at: Vector3, r: float, ink: bool) -> void:
	eng.begin_stroke()
	eng.stamp(at, N, r, Color.WHITE, 1.0, 1.0, false, {"mask": true, "stencil": true, "stencil_ink": ink, "decal": id,
		"decal_tint": false, "decal_mirror": false, "tan": PaintBrushes.decal_right(N, 0.0), "load": 1.0})
	eng.end_stroke()


## Красная краска на всю поверхность
func _paint_all(eng: PaintEngine) -> Image:
	eng.begin_stroke()
	eng.stamp(Vector3.ZERO, N, 0.75, Color(1, 0, 0), 1.0, 0.99)
	eng.end_stroke()
	await _frames(6)
	return eng.read_layer()


func _test() -> void:
	var q := _quad()
	add_child(q)
	await _frames(2)
	var eng := PaintEngine.new()
	add_child(eng)
	var ok := await eng.setup(q, RES)
	_check("setup: карта кисти построена, маски нет", ok and eng.is_built and not eng.mask_used)
	if not ok:
		return

	# скотч закрывает: краска не ложится в закрытый круг, вокруг красит
	_tape(eng, Vector3.ZERO, 0.2)
	await _frames(6)
	var only_mask := eng.read_layer()
	_check("скотч пишет в маску, а не в слой краски; отмены слоя нет", eng.mask_used and _a(only_mask, 32, 32) < 0.01 and not eng.can_undo())
	var img := await _paint_all(eng)
	_check("краска не ложится под скотч (%.2f), вокруг красит (%.2f)" % [_a(img, 32, 32), _a(img, 60, 32)], _a(img, 32, 32) < 0.05 and _a(img, 60, 32) > 0.9 and _a(img, 32, 60) > 0.9)
	_check("после краски слой даёт шаг отмены, маска его не создавала", eng.can_undo())

	# открыть: стереть скотч под мазком
	await _reset(eng)
	_tape(eng, Vector3.ZERO, 0.3)
	_tape(eng, Vector3.ZERO, 0.15, true)
	await _frames(6)
	var open_img := await _paint_all(eng)
	_check("открытие снимает скотч в центре (%.2f), кольцо вокруг остаётся закрытым (%.2f)" % [_a(open_img, 32, 32), _a(open_img, 32 + 14, 32)], _a(open_img, 32, 32) > 0.9 and _a(open_img, 32 + 14, 32) < 0.05)

	# очистка маски
	await _reset(eng)
	_tape(eng, Vector3.ZERO, 0.3)
	await _frames(4)
	eng.clear_mask()
	await _frames(6)
	var cleared := await _paint_all(eng)
	_check("очистка маски: краска ложится везде, маска сброшена", _a(cleared, 32, 32) > 0.9 and not eng.mask_used)

	# ластик защищён маской
	await _reset(eng)
	var painted := await _paint_all(eng)
	_tape(eng, Vector3.ZERO, 0.2)
	await _frames(6)
	eng.begin_stroke()
	eng.stamp(Vector3.ZERO, N, 0.75, Color.WHITE, 1.0, 0.99, true)
	eng.end_stroke()
	await _frames(6)
	var erased := eng.read_layer()
	_check("ластик стирает всё, кроме закрытого скотчем (центр %.2f, край %.2f)" % [_a(erased, 32, 32), _a(erased, 60, 32)], _a(painted, 32, 32) > 0.9 and _a(erased, 32, 32) > 0.9 and _a(erased, 60, 32) < 0.05)

	# декаль тоже не ложится под маску
	await _reset(eng)
	_tape(eng, Vector3.ZERO, 0.2)
	await _frames(6)
	eng.begin_stroke()
	eng.stamp(Vector3.ZERO, N, 0.3, Color(1, 0, 0), 1.0, 1.0, false, {"decal": "star", "decal_tint": true, "tan": PaintBrushes.decal_right(N, 0.0), "load": 1.0})
	eng.end_stroke()
	await _frames(6)
	var decal_img := eng.read_layer()
	_check("декаль не ложится под скотч (центр %.2f)" % _a(decal_img, 32, 32), _a(decal_img, 32, 32) < 0.05)

	# трафарет, картинка с прозрачностью (цвет задан, фон нет): рисунок накрывает
	_check("у стрелки есть прозрачность, у звезды тоже", PaintDecals.has_alpha("arrow") and PaintDecals.has_alpha("star"))
	await _reset(eng)
	_stencil(eng, "arrow", Vector3.ZERO, 0.4, true)
	await _frames(6)
	var st_ink := await _paint_all(eng)
	_check("трафарет «накрывает рисунок»: голова стрелки закрыта (%.2f), фон внутри рамки открыт (%.2f), вне рамки красит (%.2f)" % [_a(st_ink, 40, 23), _a(st_ink, 23, 23), _a(st_ink, 60, 60)], _a(st_ink, 40, 23) < 0.1 and _a(st_ink, 23, 23) > 0.9 and _a(st_ink, 60, 60) > 0.9)

	# тот же трафарет, накрывает фон
	await _reset(eng)
	_stencil(eng, "arrow", Vector3.ZERO, 0.4, false)
	await _frames(6)
	var st_bg := await _paint_all(eng)
	_check("трафарет «накрывает фон»: голова стрелки открыта (%.2f), фон внутри рамки закрыт (%.2f), вне рамки красит (%.2f)" % [_a(st_bg, 40, 23), _a(st_bg, 23, 23), _a(st_bg, 60, 60)], _a(st_bg, 40, 23) > 0.9 and _a(st_bg, 23, 23) < 0.1 and _a(st_bg, 60, 60) > 0.9)

	# два цвета без прозрачности: тёмная половина слева, светлая справа
	var tmp := "user://library_mask_test"
	DirAccess.make_dir_recursive_absolute(tmp)
	var two := Image.create(32, 32, false, Image.FORMAT_RGB8)
	for y in 32:
		for x in 32:
			two.set_pixel(x, y, Color.BLACK if x < 16 else Color.WHITE)
	two.save_png(tmp + "/two_tone.png")
	var saved_dirs := PaintDecals.dirs
	var saved_mixed := PaintDecals.mixed_dirs
	PaintDecals.dirs = [tmp]
	PaintDecals.mixed_dirs = []
	PaintDecals.refresh()
	_check("картинка из двух цветов без прозрачности: has_alpha ложь", PaintDecals.has("f:two_tone") and not PaintDecals.has_alpha("f:two_tone"))
	await _reset(eng)
	_stencil(eng, "f:two_tone", Vector3.ZERO, 0.4, true)
	await _frames(6)
	var tt_ink := await _paint_all(eng)
	_check("два цвета, накрывает рисунок (тёмное): слева закрыто (%.2f), справа открыто (%.2f)" % [_a(tt_ink, 20, 32), _a(tt_ink, 44, 32)], _a(tt_ink, 20, 32) < 0.1 and _a(tt_ink, 44, 32) > 0.9)
	await _reset(eng)
	_stencil(eng, "f:two_tone", Vector3.ZERO, 0.4, false)
	await _frames(6)
	var tt_bg := await _paint_all(eng)
	_check("два цвета, накрывает фон (светлое): слева открыто (%.2f), справа закрыто (%.2f)" % [_a(tt_bg, 20, 32), _a(tt_bg, 44, 32)], _a(tt_bg, 20, 32) > 0.9 and _a(tt_bg, 44, 32) < 0.1)
	DirAccess.remove_absolute(tmp + "/two_tone.png")
	DirAccess.remove_absolute(tmp)
	PaintDecals.dirs = saved_dirs
	PaintDecals.mixed_dirs = saved_mixed
	PaintDecals.refresh()

	# накладка Library показывает маску; накладка игры (PaintLayers) её не знает
	var ov := eng.make_overlay()
	_check("накладка Library знает маску и показывает её, накладка игры нет", ov.get_shader_parameter("mask_tex") != null and ov.get_shader_parameter("mask_show") == true and PaintLayers.make_overlay(eng.texture).get_shader_parameter("mask_tex") == null)

	eng.queue_free()
	q.queue_free()
	await _frames(2)


func _check(title: String, cond: bool) -> void:
	_all += 1
	if cond:
		_ok += 1
		print("PASS  ", title)
	else:
		print("FAIL  ", title)
