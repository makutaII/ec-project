class_name FieldCollision extends Node3D

# XX claude-terra 13.14 H1 (новый файл)
###################################
## Коллизия поля высот (ATTN_13 §13.14). По одному StaticBody3D с HeightMapShape3D на чанк, слой ground.
###################################
## Обновляется по отпусканию: пока поле меняют, пересборка ждёт паузы COLL_IDLE (замер H0: 0,10 мс на чанк).
## Карта высот чанка квадратная (Jolt другую не принимает): CHUNK + 1 узлов по стороне, крайний ряд берётся у соседнего чанка.
## Высота узла = пол + слой, поэтому у узлов без слоя карта лежит на полу (стол или верх листа). Ложе трака (H5) заменяет высоту узла
## (показанная поверхность), чанки только с ложем тоже получают тело.

const STEP := TerrainField.STEP
const CHUNK := TerrainField.CHUNK
## Пауза после последнего изменения, с
const COLL_IDLE := 0.25

var field: TerrainField

var _bodies := {}     # Vector2i -> StaticBody3D
var _dirty := {}      # Vector2i -> true
var _idle := 0.0
## Для проверок: сколько чанков пересобрано в последний раз и за сколько мс
var last_count := 0
var last_ms := 0.0


func _ready() -> void:
	name = &"FieldCollision"


func bind(f: TerrainField) -> void:
	field = f
	field.changed.connect(_on_changed)
	field.bed_changed.connect(_on_changed)


func _on_changed(keys: Array) -> void:
	for key: Vector2i in keys:
		# затронуты и соседи: общий ряд узлов лежит в карте соседнего чанка
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				_dirty[Vector2i(key.x + dx, key.y + dz)] = true
	_idle = 0.0


func _process(delta: float) -> void:
	if _dirty.is_empty():
		return
	_idle += delta
	if _idle >= COLL_IDLE:
		flush()


## Пересобрать коллизию грязных чанков немедленно (проверки и сейв)
func flush() -> void:
	if field == null:
		_dirty.clear()
		return
	var t0 := Time.get_ticks_usec()
	var n := 0
	for key: Vector2i in _dirty.keys():
		if field.has_chunk(key) or not field.chunk_bed(key).is_empty():
			_build(key)
			n += 1
		else:
			_remove(key)
	_dirty.clear()
	last_count = n
	last_ms = float(Time.get_ticks_usec() - t0) / 1000.0


func body_count() -> int:
	return _bodies.size()


func has_body(key: Vector2i) -> bool:
	return _bodies.has(key)


func _remove(key: Vector2i) -> void:
	if _bodies.has(key):
		var b := _bodies[key] as StaticBody3D
		_bodies.erase(key)
		if is_instance_valid(b):
			b.queue_free()


func _build(key: Vector2i) -> void:
	var i0 := key.x * CHUNK
	var j0 := key.y * CHUNK
	var n := CHUNK + 1
	var data := PackedFloat32Array()
	data.resize(n * n)
	for rz in range(n):
		for rx in range(n):
			data[rz * n + rx] = field.shown_surface_at(i0 + rx, j0 + rz)
	var hs := HeightMapShape3D.new()
	hs.map_width = n
	hs.map_depth = n
	hs.map_data = data
	var body := _bodies.get(key) as StaticBody3D
	if body == null or not is_instance_valid(body):
		body = StaticBody3D.new()
		body.name = "Chunk_%d_%d" % [key.x, key.y]
		body.collision_layer = Global.active_layers(['ground'])
		body.collision_mask = 0   # статическое тело само ничего не ищет
		body.add_child(CollisionShape3D.new())
		add_child(body)
		_bodies[key] = body
	body.position = Vector3(float(i0) * STEP, 0.0, float(j0) * STEP)
	var cs := body.get_child(0) as CollisionShape3D
	cs.shape = hs
	cs.scale = Vector3(STEP, 1.0, STEP)
	cs.position = Vector3(float(n - 1) * STEP * 0.5, 0.0, float(n - 1) * STEP * 0.5)
