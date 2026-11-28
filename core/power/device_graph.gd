class_name DeviceGraph extends RefCounted

#####################
## Граф проводки (ATTN_10 §10.5.7, D4)
#####################
## Узлы это клеммы (PowerTerminal), рёбра это провода и внутренние связи устройств (`PowerTerminal.links`).
## `drive(feeder)` идёт от клеммы клипа вверх по току до вывода источника и отвечает:
##   wired: к клемме подключён провод (физическая проводка), reachable: путь дошёл до вывода,
##   label: метка вывода (при нескольких доступных берётся меньшая), flip: нечётное число «скруток» и реверсоров на пути,
##   via: устройства (`link["via"]`), через которые идёт выбранный путь (для предохранителя: чей ток считать).
## Чистая логика без сцены: проверяется tests/device_graph_test.tscn.

var _adj: Dictionary = {}   # клемма -> Array[[другая клемма, twist: bool]]


func clear() -> void:
	_adj.clear()


func add_wire(a: PowerTerminal, b: PowerTerminal, twist: bool) -> void:
	if a == null or b == null:
		return
	if not _adj.has(a):
		_adj[a] = []
	if not _adj.has(b):
		_adj[b] = []
	_adj[a].append([b, twist])
	_adj[b].append([a, twist])


func has_wire(t: PowerTerminal) -> bool:
	return _adj.has(t) and not (_adj[t] as Array).is_empty()


## XX claude-wire W8: потребитель шины. wired: к клемме подключён провод; reachable: путь по проводам и клеммам устройств (link) дошёл до
## вывода источника вида kind (шина аксессуаров: Kind.ACCESSORY). Источник другого вида путь не завершает и дальше не проводит
func reach(start: PowerTerminal, kind: int) -> Dictionary:
	var res := {"wired": has_wire(start), "reachable": false}
	if not res.wired:
		return res
	var seen: Dictionary = {start: true}
	var stack: Array = [start]
	while not stack.is_empty():
		var t: PowerTerminal = stack.pop_back()
		var next: Array = []
		for e in (_adj.get(t, []) as Array):
			next.append(e[0])
		for l in t.links():
			next.append(l["terminal"])
		for nt in next:
			if nt == null or seen.has(nt):
				continue
			seen[nt] = true
			if nt.role == PowerTerminal.Role.SRC:
				if nt.kind == kind:
					res.reachable = true
					return res
				continue
			stack.append(nt)
	return res


## Ответ для клеммы клипа
func drive(feeder: PowerTerminal) -> Dictionary:
	var res := {"wired": has_wire(feeder), "reachable": false, "label": 0, "flip": false, "via": []}
	if not res.wired:
		return res
	var best_label := 0
	var best_flip := false
	var best_via: Array = []
	var seen: Dictionary = {feeder: true}
	var stack: Array = [[feeder, false, []]]
	while not stack.is_empty():
		var cur: Array = stack.pop_back()
		var t: PowerTerminal = cur[0]
		var fl: bool = cur[1]
		var path: Array = cur[2]
		var next: Array = []
		for e in (_adj.get(t, []) as Array):
			next.append([e[0], fl != bool(e[1]), path])
		for l in t.links():
			var p2: Array = path
			if l.get("via") != null:
				p2 = path + [l["via"]]
			next.append([l["terminal"], fl != bool(l["flip"]), p2])
		for n in next:
			var nt: PowerTerminal = n[0]
			if nt == null or seen.has(nt):
				continue
			seen[nt] = true
			if nt.role == PowerTerminal.Role.SRC and nt.output_label > 0:
				if best_label == 0 or nt.output_label < best_label:
					best_label = nt.output_label
					best_flip = n[1]
					best_via = n[2]
				continue   # источник не проводит дальше
			stack.append([nt, n[1], n[2]])
	res.reachable = best_label > 0
	res.label = best_label
	res.flip = best_flip
	res.via = best_via
	return res
