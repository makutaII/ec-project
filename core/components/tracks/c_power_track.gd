class_name C_PowerTrack extends IPowerable

##################################
## Библиотека действий. Она живет на объекте всегда.
##################################
## способность проводить ток 
## компонент принимает напряжение, передает другим сущностям


#var voltage: float #текущее напряжение не используется
#var power_schema_mesh : PlaneMesh

# XX claude-switch: лучи (legs). У обычного трака и стрелки один луч, контур и полярность одни на всю сущность.
# У кросса с раздельными цепями два луча (по одному на путь): каждый запитывается и разворачивается независимо.
# net_id (бывший contour_id) и is_flipped всегда луч 0, поэтому весь старый код работает как раньше. Тележка на кроссе
# спрашивает свой луч: contour_of(bogie.route), flip_of(bogie.route). Номер за пределами лучей = последний луч
var legs: int = 1
var _contours: Array[int] = [0]
var _flips: Array[bool] = [false]

## Авария на траке: противоречие полярности (КЗ реверсивной петли) или перепутанные провода клипа.
## Выставляет RailNetBuilder при пересчете сети, в сейв не пишется (считается заново)
var fault: bool = false

# Цепь питания (раньше contour_id). 0 - не подключен к клипу (луч 0)
var net_id :int:
	get:
		return _contours[0]
	set(val):
		_contours[0] = val

# разворот пути относительно эталонного(клип-трак - эталон) (луч 0)
var is_flipped :bool:
	get:
		return _flips[0]
	set(val):
		_flips[0] = val


## Сколько независимых лучей у сущности (C_CrossingShape ставит 2 при раздельных цепях)
func set_legs(n: int) -> void:
	n = maxi(n, 1)
	if n == legs:
		return
	legs = n
	_contours.resize(n)
	_flips.resize(n)


func contour_of(leg: int) -> int:
	return _contours[clampi(leg, 0, legs - 1)]


func flip_of(leg: int) -> bool:
	return _flips[clampi(leg, 0, legs - 1)]


func set_leg(leg: int, cid: int, flipped: bool) -> void:
	var i := clampi(leg, 0, legs - 1)
	_contours[i] = cid
	_flips[i] = flipped


## Сбросить все лучи (PGM перед пересчетом сети)
func reset() -> void:
	for i in legs:
		_contours[i] = 0
		_flips[i] = false


func has_contour() -> bool:
	for c in _contours:
		if c != 0:
			return true
	return false


## Для InfoPanel: "3" или "3 | 5" у кросса с раздельными цепями
func contour_text() -> String:
	var parts: PackedStringArray = []
	for c in _contours:
		parts.append(str(c))
	return " | ".join(parts)


func voltage_text() -> String:
	var parts: PackedStringArray = []
	for c in _contours:
		parts.append(str(PGM.get_power(c)))
	return " | ".join(parts)


func flip_text() -> String:
	var parts: PackedStringArray = []
	for f in _flips:
		parts.append(str(f))
	return " | ".join(parts)



func on_added():
	entity.add_to_group('power_track')
	pass
	

func on_entity_ready() -> void:
	pass



func on_removed():
	# Если рельс удалили (DragTool/Delete), нужно пнуть менеджера пересчитать сеть
	if has_contour():
		PGM.request_recalculate()


# Сейв данных по запросу ентити
func save_data() -> Dictionary:
	return {
		# не исп
		'comp_path':get_script().resource_path, #  "res://core/components/c_power_clip.gd"
		# не исп, для наглядности в сейве
		'comp_name':get_script().resource_path.get_file().get_basename(), # "c_power_clip"
		"net_id": net_id,
		"contour_id": net_id,   # старый ключ: сейв читается и старыми версиями
		#"voltage": voltage,
		"is_flipped": is_flipped,
		"leg_contours": _contours.duplicate(),   # XX claude-switch: все лучи
		"leg_flips": _flips.duplicate(),
	}



func load_data(_data: Dictionary) -> void:
	# net_id новый ключ, contour_id из старых сейвов
	if _data.has("net_id"):
		net_id = _data.net_id
	elif _data.has("contour_id"):
		net_id = _data.contour_id
	#if _data.has("voltage"):
		#voltage = _data.voltage
	if _data.has("is_flipped"):
		is_flipped = _data.is_flipped
	# XX claude-switch: лучи 1.. (число лучей задала форма при сборке сущности)
	var lc: Array = _data.get("leg_contours", [])
	var lf: Array = _data.get("leg_flips", [])
	for i in mini(legs, lc.size()):
		_contours[i] = int(lc[i])
	for i in mini(legs, lf.size()):
		_flips[i] = bool(lf[i])


## Строки подсказки при наведении и вкладки «Подсказки» (контракт HoverLines, U5a.5)
func get_hover_lines() -> Array:
	return [HoverLines.line("Контур: %s, напряжение: %s" % [contour_text(), voltage_text()])]
