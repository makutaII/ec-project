class_name C_TrackSupport extends ICapability

# XX claude-terra (новый файл)
####################
## Способность. Эстакада под траком.
####################
## Семплирует кривую C_Path, бросает лучи вниз и ставит опоры (ригель + столб), где зазор до земли
## больше GlobalSetting.support_min_clearance. Под чужим траком опоры не ставятся (пролет).
## Владеет MultiMeshInstance3D и StaticBody3D (слой supports, 13.1.5): сошедший вагон встает на опоры, а не
## проваливается сквозь эстакаду. Коллизий у призрака и трака в драге нет. НЕ сохраняется: считается из пути и земли.
## Дедупликация на стыке (13.1.5): общую опору у конца строит один из двух траков (с меньшим instance id),
## второй свою опору в этой точке пропускает.
## Земля = стол или верх листа пенопласта (13.1.3). Лист ставят и убирают под готовым траком:
## пересчет по TGM.terrain_changed, а не по таймеру.
## XX claude-perf: компонент НЕ опрашивает мир в простое. Физический процесс включается только когда есть
## что делать (первый расчет после создания, пересчет по событию, трак или призрак двигают) и сам выключается,
## когда расчет сделан. Фонового пересчета "на всякий случай" нет: все причины изменения приходят событиями
## (создание, сдвиг, форма, маршруты стрелки, лист пенопласта, удаление трака через TGM.terrain_changed).

const DRAG_PERIOD := 0.05    # с, не чаще при движении призрака/трака
const SPREAD := 0.15         # с, случайный разброс пересчетов, чтобы 500 траков не пересчитывались в один тик

static var _wood: StandardMaterial3D

var _mmi: MultiMeshInstance3D
var _dirty := true
var _cooldown := 0.3         # после загрузки сейва ждем, пока встанут все коллизии
var _acc := 0.0              # XX claude-perf: накопленное время с прошлой проверки
var _last_entity_xf := Transform3D()
var _last_xf: Array[Transform3D] = []

# XX claude-terra 13.1.5: коллизии опор
var _body: StaticBody3D
var _shapes: Array[CollisionShape3D] = []   # пул, форм столько же, сколько боксов
var _box_t: Array[Transform3D] = []         # позы боксов без масштаба (в системе Entity)
var _box_s: Array[Vector3] = []             # размеры боксов
var _coll_dirty := false                    # коллизии надо пересобрать, хотя боксы те же (драг закончился)


func on_entity_ready() -> void:
	_dirty = true
	_cooldown = 0.3 + randf() * SPREAD   # разброс: загрузка сейва создает сотни траков в один кадр
	set_physics_process(true)
	TGM.terrain_changed.connect(_on_terrain_changed)   # XX claude-terra T3
	# T5: трак встал, листы под ним пересчитают канаву. Отложено: призрак получает C_Ghost после готовности
	call_deferred("_notify_terrain")


## Лист пенопласта поставлен, сдвинут или убран: земля под опорами могла измениться.
## Не фильтруем по области: событие редкое (дроп, постановка, удаление), пересчет дешевый
func _on_terrain_changed(_aabb: AABB) -> void:
	_wake(randf() * SPREAD)   # событие рассылается всем опорам, разброс убирает вспышку в один тик


func on_drag_ended(_d: Dictionary) -> void:
	_wake(0.0)
	_notify_terrain()   # T5: трак сдвинули, листам пересчитать канаву


## flex поменял форму
func on_curve_changed(_d: Dictionary) -> void:
	_wake(0.0)
	call_deferred("_sync_shadows")   # flex пересобрал меши: у новых узлов тени по настройке качества
	_notify_terrain()   # T6: форма flex поменялась, листам пересчитать канаву или тоннель


## T6: тоннельный флаг включили или выключили (C_Tunnel). Отложено: компонент в момент события еще
## (при снятии) числится в Entity
func on_tunnel_changed(_d: Dictionary) -> void:
	call_deferred("_notify_terrain")


## XX claude-terra 13.14 H5c: режим ложа или откос бортов трака сменили (C_Path.set_bed_mode, set_bed_steep). Отложено, как у тоннеля
func on_bed_changed(_d: Dictionary) -> void:
	call_deferred("_notify_terrain")


## XX claude-switch: стрелка получила маршруты
func on_routes_changed(_d: Dictionary) -> void:
	_wake(0.0)
	call_deferred("_sync_shadows")


func _exit_tree() -> void:
	_notify_terrain()   # T5: трак убрали, канава под ним больше не нужна


## T5, T6. Сообщает листам, что трак встал, сдвинулся, поменял форму или флаг, либо убран.
## Область = контур балласта от низа балласта до верха трака (у тоннельного еще и габарит).
## Призраки и траки в драге не сообщают. Удаляемый трак сообщает (TGM.get_tracks его уже не отдаст)
func _notify_terrain() -> void:
	if not is_instance_valid(TGM) or entity == null or not entity.is_inside_tree():
		return
	if entity.has_comp(C_Ghost) or entity.has_comp(C_Drag):
		return
	var path := get_comp(C_Path) as C_Path
	if path == null:
		return
	var s := path.ballast_samples()
	if s.size() < 2:
		return
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var y_lo := INF
	var y_hi := -INF
	for d in s:
		var l: Vector2 = d["l"]
		var r: Vector2 = d["r"]
		lo = lo.min(l).min(r)
		hi = hi.max(l).max(r)
		var y: float = d["y"]
		y_lo = minf(y_lo, y)
		y_hi = maxf(y_hi, y)
	var top: float = y_hi + Global.settings.get_track_height()
	if path.allows_underground():
		top += Global.settings.tunnel_clearance
	TGM.notify_changed(AABB(Vector3(lo.x, y_lo, lo.y), Vector3(hi.x - lo.x, top - y_lo, hi.y - lo.y)))


## XX claude-terra 13.1.5: у соседа по стыку появился или исчез трак (C_Socket), решение "кто строит общую опору" могло смениться
func on_neighbors_changed(_d: Dictionary) -> void:
	_wake(0.0)


func on_component_added(_t: Script) -> void:
	_apply_material()
	_apply_collision_state()
	if _is_moving():
		set_physics_process(true)   # трак взяли в драг или это призрак: следим за смещением


func on_component_removed(_t: Script) -> void:
	_apply_material()
	_apply_collision_state()


## Разбудить расчет. delay: через сколько секунд можно пересчитывать
func _wake(delay: float) -> void:
	_dirty = true
	_cooldown = delay
	set_physics_process(true)


## Двигают ли сейчас этот трак: призрак постановки или драг. Только тогда опрашиваем позицию
func _is_moving() -> bool:
	return entity != null and (entity.has_comp(C_Ghost) or entity.has_comp(C_Drag))


func _sync_shadows() -> void:
	if entity != null and entity.is_inside_tree():
		TrackShadows.apply(entity)


func _physics_process(delta: float) -> void:
	# Не чаще DRAG_PERIOD: пересчет и так ограничен кулдауном, проверять каждый из 120 тиков в секунду незачем
	_acc += delta
	if _acc < DRAG_PERIOD:
		return
	delta = _acc
	_acc = 0.0
	if not entity or not entity.is_inside_tree() or entity.is_queued_for_deletion():
		return
	_cooldown -= delta
	var moving := _is_moving()
	if moving:
		var xf := entity.global_transform
		if not xf.is_equal_approx(_last_entity_xf):
			_last_entity_xf = xf
			_dirty = true
	if _dirty and _cooldown <= 0.0:
		_dirty = false
		_cooldown = DRAG_PERIOD
		_rebuild()
	if not _dirty and not moving:
		set_physics_process(false)   # расчет сделан, до следующего события процесс спит


func _rebuild() -> void:
	var path := get_comp(C_Path) as C_Path
	if not path or not path.curve or not path.path_node:
		return
	var gs = Global.settings
	var space := entity.get_world_3d().direct_space_state
	var inv := entity.global_transform.affine_inverse()
	var xf: Array[Transform3D] = []
	var bt: Array[Transform3D] = []
	var bs: Array[Vector3] = []
	# XX claude-terra 13.1.5: общую опору на стыке строит один из двух траков, второй свою в этой точке пропускает.
	# Стрелка и кросс считают опоры на каждый маршрут, стык у них не дедуплицируем
	var skip_start := false
	var skip_end := false
	if not path.is_multi_route():
		skip_start = _yields_joint(false)
		skip_end = _yields_joint(true)

	for crv in path.all_curves():   # XX claude-switch: у стрелки опоры под всеми маршрутами
		var length := crv.get_baked_length()
		var n := maxi(1, ceili(length / gs.support_step))
		for i in n + 1:
			var t := crv.sample_baked_with_rotation(length * i / n)
			var p := path.path_node.to_global(t.origin)          # низ балласта
			var fwd := path.path_node.global_basis * -t.basis.z
			fwd.y = 0.0
			if fwd.length_squared() < 0.0001:
				continue
			if (i == 0 and skip_start) or (i == n and skip_end):
				continue
			var yaw := Basis.looking_at(fwd.normalized(), Vector3.UP)
			# XX claude-coaster: у трака с креном ригель наклонён вместе с лотком (вращение вокруг низа балласта p),
			# иначе один край трака уходил в горизонтальный ригель, а другой висел над ним. Без крена всё прежнее
			var roll := TrackMeshBuilder.roll_at(crv, length * i / n, length)
			var beam := yaw
			var beam_c := p - Vector3(0, 0.15, 0)
			var beam_drop := 0.3                  # на сколько ниже p кончается низ ригеля по центру
			var beam_size := path.support_beam_size()   # XX claude-car CS1c: у дороги по ширине полотна, у рельсов прежние 3.0 x 0.3 x 0.8
			var pillar := path.support_pillar_size()
			var beam_extra := 0.0                 # просадка нижнего конца ригеля от наклона (полуширина ригеля)
			if roll != 0.0:
				beam = yaw * Basis(Vector3(0, 0, -1), roll)
				beam_c = p - beam.y * 0.15
				beam_drop = 0.3 * beam.y.y
				beam_extra = beam_size.x * 0.5 * absf(sin(roll))
			var ground := _ground_y(space, p, path)
			if is_nan(ground) or p.y - ground < gs.support_min_clearance + beam_extra:
				continue
			var col_h := p.y - ground - beam_drop
			# ригель под балластом
			_add_box(xf, bt, bs, inv, beam, beam_size, beam_c)
			# столб
			if col_h > 0.05:
				_add_box(xf, bt, bs, inv, yaw, Vector3(pillar.x, col_h, pillar.y), Vector3(p.x, ground + col_h * 0.5, p.z))

	if xf == _last_xf and not _coll_dirty:
		return
	_last_xf = xf
	_box_t = bt
	_box_s = bs
	if xf.is_empty() and not _mmi:
		return
	_ensure_nodes()
	var mm := _mmi.multimesh
	mm.instance_count = xf.size()
	for i in xf.size():
		mm.set_instance_transform(i, xf[i])
	_sync_collision()


## XX claude-terra 13.1.5. Один бокс опоры: масштабная поза для MultiMesh и поза с размером для коллизии
## (у CollisionShape3D масштаб не задают, размер лежит в BoxShape3D)
func _add_box(xf: Array[Transform3D], bt: Array[Transform3D], bs: Array[Vector3],
		inv: Transform3D, yaw: Basis, size: Vector3, center: Vector3) -> void:
	xf.append(inv * Transform3D(yaw * Basis.from_scale(size), center))
	bt.append(inv * Transform3D(yaw, center))
	bs.append(size)


## XX claude-terra 13.1.5. Этот стык строит опору не я, а сосед: он пристыкован к краю моей кривой, тоже имеет
## эстакаду и у него меньший instance id. Тогда в точке стыка у меня боксов нет, у соседа есть (там та же точка и
## тот же грунт). Не зависит от драга: связь пропадает с выходом сокета, а удаление соседа будит все опоры
func _yields_joint(is_end: bool) -> bool:
	var sock := get_comp(C_Socket) as C_Socket
	if sock == null:
		return false
	var nb := sock.get_neighbor_at(is_end)
	if nb == null or nb.is_queued_for_deletion() or nb.has_comp(C_Ghost) or not nb.has_comp(C_TrackSupport):
		return false
	return nb.get_instance_id() < entity.get_instance_id()


## XX claude-terra 13.1.5. Коллизии опор: один StaticBody3D на слое supports, формы из пула.
## Пока трак призрак или в драге, слой выключен (а формы не трогаем: пересоберутся по окончании драга)
func _sync_collision() -> void:
	if _is_moving():
		_coll_dirty = true
		_apply_collision_state()
		return
	_coll_dirty = false
	if _box_t.is_empty() and _body == null:
		return
	if _body == null:
		_body = StaticBody3D.new()
		_body.name = "SupportsBody"
		_body.collision_mask = 0
		entity.add_child(_body)
	while _shapes.size() > _box_t.size():
		_shapes.pop_back().queue_free()
	while _shapes.size() < _box_t.size():
		var cs := CollisionShape3D.new()
		cs.shape = BoxShape3D.new()
		_body.add_child(cs)
		_shapes.append(cs)
	for i in _box_t.size():
		_shapes[i].transform = _box_t[i]
		(_shapes[i].shape as BoxShape3D).size = _box_s[i]
	_apply_collision_state()


func _apply_collision_state() -> void:
	if _body == null:
		return
	_body.collision_layer = 0 if _is_moving() else Global.active_layers(['supports'])


## NAN: под нами чужой трак, значит пролет без опоры. Нет попадания: стол (y = 0).
## Лист пенопласта и поле высот берем еще и аналитически (TGM.surface_y, TGM.field_shown_y): луч стартует на 0,02 ниже балласта,
## и если балласт заглублен в лист (в пределах underground_tolerance), старт оказывается внутри
## выпуклого шейпа листа, и луч проходит насквозь. Аналитика не зависит от физического кадра
func _ground_y(space: PhysicsDirectSpaceState3D, p: Vector3, path: C_Path) -> float:
	var q := PhysicsRayQueryParameters3D.create(p - Vector3(0, 0.02, 0), p - Vector3(0, 500, 0),
			Global.active_layers(['ground', 'tracks', 'roads']))   # XX claude-car CS1c: под рельсом или дорогой может быть дорога, это пролёт
	q.collide_with_areas = true               # балласт это Area3D
	var own: Array[RID] = []
	if path.ballast_node:
		own.append(path.ballast_node.get_rid())
	if path.head_node:
		own.append(path.head_node.get_rid())
	q.exclude = own
	var hit := space.intersect_ray(q)
	var y := 0.0
	if not hit.is_empty():
		var e := _entity_of(hit.collider)
		if e and e != entity and e.has_comp(C_Path):
			return NAN
		y = hit.position.y
	var tol: float = Global.settings.underground_tolerance
	# XX claude-terra 13.14 H5: поле высот (с ложем трака) берём так же аналитически: стойка кончается у земли, а не у стола
	return maxf(maxf(y, TGM.surface_y(p.x, p.z, p.y + tol)), TGM.field_shown_y(p.x, p.z, p.y + tol))


func _ensure_nodes() -> void:
	if _mmi:
		return
	_mmi = MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = BoxMesh.new()                   # единичный бокс, размер задаем scale'ом
	_mmi.multimesh = mm
	_mmi.name = 'Supports'
	entity.add_child(_mmi)
	TrackShadows.apply(_mmi)
	_apply_material()


func _apply_material() -> void:
	if not _mmi:
		return
	if not _wood:
		_wood = StandardMaterial3D.new()
		_wood.albedo_color = Color(0.62, 0.45, 0.28)
	_mmi.material_override = _wood
	var vis := get_comp(C_TrackVisual) as C_Visual
	var overlay: Material = null
	if vis and vis.visual_settings:
		if has_comp(C_Blocked):
			overlay = vis.visual_settings.blocked_material
		elif has_comp(C_Ghost):
			overlay = vis.visual_settings.ghost_material
	_mmi.material_overlay = overlay


func _entity_of(n: Node) -> Entity:
	while n:
		if n is Entity:
			return n
		n = n.get_parent()
	return null
