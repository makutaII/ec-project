extends Node

# XX claude-terra 13.13 K5 (новый файл)
## Тест портала тоннеля: устья, проём, коробки рамки, стили. Сцены не нужно.
## Запуск: tests/tunnel_portal_test.tscn, F6, строки PASS / FAIL в Output.

var _fails := 0


func check(name: String, ok: bool, info := "") -> void:
	if ok:
		print("PASS  ", name)
	else:
		_fails += 1
		print("FAIL  ", name, "  ", info)


## Образцы прямого трака вдоль оси X от x0 до x1 на z = zc, шаг 2 ю, ширина балласта 2, низ y
func _samples(x0: float, x1: float, zc: float, y: float) -> Array:
	var res: Array = []
	var x := x0
	while x <= x1 + 0.001:
		res.append({"l": Vector2(x, zc + 1.0), "r": Vector2(x, zc - 1.0), "y": y})
		x += 2.0
	return res


func _ready() -> void:
	var sq := PackedVector2Array([Vector2(0, 0), Vector2(20, 0), Vector2(20, 20), Vector2(0, 20)])

	# устья
	var m := TunnelPortal.mouths(_samples(-10, 10, 10, 0.0), sq)
	check("устье: трак заходит слева, одно устье", m.size() == 1, str(m.size()))
	if m.size() == 1:
		check("устье: точка на контуре", absf((m[0]["p"] as Vector2).x) < 0.001 and absf((m[0]["p"] as Vector2).y - 10.0) < 0.001)
		check("устье: нормаль наружу против хода", (m[0]["out"] as Vector2).is_equal_approx(Vector2(-1, 0)), str(m[0]["out"]))
		check("устье: ширина балласта", is_equal_approx(float(m[0]["width"]), 2.0))
		check("устье: поперёк трака единичный", absf((m[0]["across"] as Vector2).length() - 1.0) < 0.001)
	var m2 := TunnelPortal.mouths(_samples(-10, 30, 10, 0.0), sq)
	check("устье: насквозь два устья", m2.size() == 2, str(m2.size()))
	var outs := 0
	for r in m2:
		if (r["out"] as Vector2).is_equal_approx(Vector2(-1, 0)) or (r["out"] as Vector2).is_equal_approx(Vector2(1, 0)):
			outs += 1
	check("устье: нормали противоположны", outs == 2 and not (m2[0]["out"] as Vector2).is_equal_approx(m2[1]["out"]))
	check("устье: трак целиком вне листа нет устьев", TunnelPortal.mouths(_samples(-10, -2, 10, 0.0), sq).is_empty())
	check("устье: трак целиком внутри нет устьев", TunnelPortal.mouths(_samples(4, 16, 10, 0.0), sq).is_empty())
	var m3 := TunnelPortal.mouths(_samples(10, 30, 10, 0.0), sq)
	check("устье: трак начинается внутри, одно устье справа с нормалью наружу", m3.size() == 1 and (m3[0]["out"] as Vector2).is_equal_approx(Vector2(1, 0)))
	var diag: Array = [
		{"l": Vector2(-9, -11), "r": Vector2(-11, -9), "y": 0.0},
		{"l": Vector2(11, 9), "r": Vector2(9, 11), "y": 0.0}]
	var m4 := TunnelPortal.mouths(diag, sq)
	check("устье: диагональ через угол даёт не больше двух устьев без дублей", m4.size() >= 1 and m4.size() <= 2, str(m4.size()))
	check("устье: слишком мало образцов", TunnelPortal.mouths([], sq).is_empty() and TunnelPortal.mouths(_samples(0, 0, 0, 0.0), sq).is_empty())

	# проём (слой 0,8: низ листа 0, 10 слоёв, габарит 5 + путь 1 = 6)
	var T := 0.8
	var op := TunnelPortal.opening(0.0, 0.0, 0.0, 10, T, 6.0, 0.1)
	check("проём: дно у низа листа", not op.is_empty() and is_equal_approx(float(op["floor"]), 0.0))
	check("проём: свод по слою над габаритом", not op.is_empty() and is_equal_approx(float(op["vault"]), 8 * T), str(op))
	check("проём: свод ниже верха листа", not op.is_empty() and float(op["vault"]) < 10 * T)
	check("проём: лист ниже габарита это канава, портала нет", TunnelPortal.opening(0.0, 0.0, 0.0, 5, T, 6.0, 0.1).is_empty())
	check("проём: трак на листе листа не касается", TunnelPortal.opening(8.0, 8.0, 0.0, 10, T, 6.0, 0.1).is_empty())
	check("проём: трак выше габарита листа не касается", TunnelPortal.opening(12.0, 12.0, 0.0, 10, T, 6.0, 0.1).is_empty())
	var op2 := TunnelPortal.opening(1.7, 1.7, 0.0, 12, T, 6.0, 0.1)
	check("проём: дно по слою под балластом", not op2.is_empty() and is_equal_approx(float(op2["floor"]), 2 * T), str(op2))

	# коробки
	var ps := TunnelPortal.parts(3.0, 0.0, 6.4, 8.0)
	check("рамка: 2 стойки, 2 фаски, 2 крыла, перемычка", ps.size() == 7, str(ps.size()))
	var left := 0
	var right := 0
	for p in ps:
		var pos: Vector3 = p["pos"]
		if pos.x < -0.01:
			left += 1
		elif pos.x > 0.01:
			right += 1
	check("рамка: зеркальна по x", left == 3 and right == 3, "%d и %d" % [left, right])
	var lintel: Dictionary = ps[ps.size() - 1]
	check("рамка: перемычка над сводом", float((lintel["pos"] as Vector3).y) - float((lintel["size"] as Vector3).y) * 0.5 >= 6.4 - 0.001)
	check("рамка: перемычка не выше верха листа", float((lintel["pos"] as Vector3).y) + float((lintel["size"] as Vector3).y) * 0.5 <= 8.0 + 0.001)
	var post: Dictionary = ps[0]
	check("рамка: стойка от дна до свода", is_equal_approx(float((post["size"] as Vector3).y), 6.4) and absf(float((post["pos"] as Vector3).x)) > 1.5)
	var all_out := true
	for p in ps:
		if float((p["pos"] as Vector3).z) < 0.0:
			all_out = false
	check("рамка: вся наружу от стенки", all_out)
	check("рамка: нулевой проём без коробок", TunnelPortal.parts(3.0, 5.0, 5.0, 8.0).is_empty() and TunnelPortal.parts(0.0, 0.0, 5.0, 8.0).is_empty())
	var tall := TunnelPortal.parts(3.0, 0.0, 6.4, 6.5)
	check("рамка: узкий запас до верха листа даёт короткую перемычку", float(((tall[tall.size() - 1]["size"]) as Vector3).y) >= 0.2 - 0.001)

	# узел рамки
	var node := TunnelPortal.make_node(TunnelPortal.STYLE_STONE, Vector2(5, 7), Vector2(-1, 0), 3.0, 0.0, 6.4, 8.0)
	check("узел: коробки как в parts", node.get_child_count() == 7)
	check("узел: в мире у устья", node.position.is_equal_approx(Vector3(5, 0, 7)))
	var zdir := node.transform.basis * Vector3(0, 0, 1)
	check("узел: локальный z смотрит наружу", zdir.is_equal_approx(Vector3(-1, 0, 0)), str(zdir))
	check("узел: правый базис", node.transform.basis.determinant() > 0.99)
	node.free()

	# стили
	check("стили: круг нет, бетон, камень, нет", TunnelPortal.next_style(&"") == &"concrete" and TunnelPortal.next_style(&"concrete") == &"stone" and TunnelPortal.next_style(&"stone") == &"")
	check("стили: неизвестный сводится к «нет»", TunnelPortal.next_style(&"gold") == &"")

	var t := C_Tunnel.new()
	check("C_Tunnel: по умолчанию портала нет, сейв без поля", t.portal == &"" and t.save_data() == {"on": true})
	t.portal = &"stone"
	var d := t.save_data()
	check("C_Tunnel: сейв хранит стиль", d.get("portal") == "stone" and d.get("on") == true)
	var t2 := C_Tunnel.new()
	t2.load_data(d)
	check("C_Tunnel: загрузка возвращает стиль", t2.portal == &"stone")
	t2.load_data({"on": true})
	check("C_Tunnel: старый сейв без поля это «нет»", t2.portal == &"")
	t2.load_data({"on": true, "portal": "gold"})
	check("C_Tunnel: неизвестный стиль это «нет»", t2.portal == &"")
	t.free()
	t2.free()

	print("---- tunnel_portal_test: ", "ВСЕ PASS" if _fails == 0 else "ПРОВАЛОВ: %d" % _fails)
