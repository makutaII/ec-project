class_name PaintEngine extends Node

# XX claude-library (новый файл)
########################
## PaintEngine. Движок кисти: слой краски по UV2 и штампы по 3D-позиции (ATTN_22 §22.7.2.1, шаг C2.1)
########################
## Слой краски это SubViewport (RGBA8, UV2 меша), в который штампы дорисовываются шейдером stamp.gdshader
## (накопление: clear ONCE, blend_mix). Позиция и нормаль каждого текселя берутся из карты позиций (PaintBake).
## Ластик: stamp_erase.gdshader (blend_mul). Отмена и повтор: снимки слоя (сжатые FastLZ), возврат через copy.gdshader.
## Слой хранит премультиплицированный цвет в sRGB (так 2D пишет в пустой буфер): см. overlay.gdshader.
## Прототип C2.0 подтвердил: накопление, набор краски, цена прохода 32 штампов (0.6 мс GPU на 512, 1.8 мс на 1024),
## снимок для отмены (чтение 18-22 мс, 4-18 КБ после сжатия).
## Узел должен стоять в дереве до setup(): нужны SubViewport и кадры. Карта позиций строится в рабочем потоке.
## Один слой на модель: общий атлас UV2 всех мешей группы (PaintBake.group). Позиции и нормали карты, штампы и радиус кисти
## лежат в пространстве опорного меша (target, самый крупный); остальные меши группы пересчитываются в него по позе покоя.

signal changed          ## слой изменился (штамп, отмена, повтор, очистка)

const MAX_STAMPS := 32
const HISTORY_LIMIT := 30
const DEFAULT_RES := 1024
const BLOCK_EPS := 0.0001          ## закрывающий меш должен быть ближе красимого хотя бы на столько (мир)
const STAMP_SHADER := preload("res://core/library/paint/stamp.gdshader")
const ERASE_SHADER := preload("res://core/library/paint/stamp_erase.gdshader")
const COPY_SHADER := preload("res://core/library/paint/copy.gdshader")

var res := DEFAULT_RES
## Опорный меш: его локальные координаты это пространство штампов и карты позиций
var target: MeshInstance3D
## Красимые меши группы (опорный первым); у всех общий слой
var meshes: Array[MeshInstance3D] = []
## Меши с UV2, не вошедшие в группу из-за перекрытия атласа: не красятся, но закрывают собой краску
var skipped: Array[MeshInstance3D] = []
## Наибольший габарит группы мешей (единицы опорного меша): радиус кисти задаётся долей от него
var size_ref := 1.0
var is_built := false
var bake_info: Dictionary = {}
var texture: Texture2D:
	get:
		return _vp.get_texture() if _vp != null else null

var _vp: SubViewport
var _rect: ColorRect
var _stamp_mat: ShaderMaterial
var _erase_mat: ShaderMaterial
var _copy_mat: ShaderMaterial
var _entries: Array = []            # [{surfaces, verts, xform}] по кандидатам, только на время запекания
var _parts: Array = []              # красимые: [{mi, tri, to_root}]
var _blockers: Array = []           # не красимые: [{mi, tri}]
var _bake_result: Dictionary = {}
var _queue: Array = []              # [{p, n, color, flow, hardness, erase}]
var _stroke_open := false
var _dirty := false
var _idle_frames := 0
var _restoring := false
var _history: Array = []            # сжатые снимки RGBA8
var _hist_index := 0
var _raw_size := 0


## Меши с UV2 на всех поверхностях: кандидаты на кисть (дёшево, без проверки перекрытий)
static func candidates(source: Array) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for m in source:
		if m is MeshInstance3D and is_instance_valid(m) and PaintBake.has_uv2((m as MeshInstance3D).mesh):
			out.append(m as MeshInstance3D)
	return out


## Строит карту позиций (в потоке) и слой для группы мешей общего атласа UV2. candidate_meshes: меш или массив мешей
## (берутся с UV2). Опорный меш (больше всего вершин) задаёт пространство штампов; остальные входят, пока их UV2 не
## перекрывает занятое (PaintBake.group). blockers: прочие меши модели: видимые не пропускают краску сквозь себя.
## false: красить нечем (нет UV2 или карта пустая). Узел уже в дереве
func setup(candidate_meshes: Variant, p_res: int = DEFAULT_RES, blockers: Array = []) -> bool:
	var list: Array[MeshInstance3D] = []
	if candidate_meshes is MeshInstance3D:
		list = candidates([candidate_meshes])
	elif candidate_meshes is Array:
		list = candidates(candidate_meshes)
	if list.is_empty():
		return false
	res = p_res
	var entries: Array = []
	for mi in list:
		var surfaces := PaintBake.collect(mi.mesh)
		var verts := 0
		for surf in surfaces:
			verts += (surf["verts"] as PackedVector3Array).size()
		entries.append({"surfaces": surfaces, "verts": verts, "xform": Transform3D.IDENTITY})
	var root := list[PaintBake.seed_index(entries)]
	if root.is_inside_tree():
		var inv := root.global_transform.affine_inverse()
		for i in list.size():
			if list[i].is_inside_tree():
				entries[i]["xform"] = inv * list[i].global_transform
	_entries = entries
	var id := WorkerThreadPool.add_task(_bake_job, false, "Library: карта кисти")
	while not WorkerThreadPool.is_task_completed(id):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(id)
	bake_info = _bake_result
	_entries = []
	if not bake_info.get("ok", false):
		return false
	_collect_parts(list, entries, root, blockers)
	_build_viewport()
	await _settle()
	_history = [_compress_layer()]
	_hist_index = 0
	is_built = true
	return true


func _bake_job() -> void:
	_bake_result = PaintBake.bake_group(_entries, res)


## Красимые части (с пересчётом в пространство опорного меша), закрывающие меши и габарит группы
func _collect_parts(list: Array[MeshInstance3D], entries: Array, root: MeshInstance3D, blockers: Array) -> void:
	target = root
	meshes.clear()
	skipped.clear()
	_parts.clear()
	_blockers.clear()
	var included: PackedInt32Array = bake_info.get("included", PackedInt32Array())
	var skip_idx: PackedInt32Array = bake_info.get("skipped", PackedInt32Array())
	var box := AABB()
	var has_box := false
	for i in included:
		var mi := list[i]
		var xf: Transform3D = entries[i]["xform"]
		meshes.append(mi)
		var tri := mi.mesh.generate_triangle_mesh()
		if tri != null:
			_parts.append({"mi": mi, "tri": tri, "to_root": xf})
		var bb: AABB = xf * mi.mesh.get_aabb()
		box = bb if not has_box else box.merge(bb)
		has_box = true
	size_ref = maxf(box.size.x, maxf(box.size.y, box.size.z))
	if size_ref <= 0.0:
		size_ref = 1.0
	var covers: Array = []
	for i in skip_idx:
		skipped.append(list[i])
		covers.append(list[i])
	for m in blockers:
		if m is MeshInstance3D and is_instance_valid(m) and (m as MeshInstance3D).mesh != null:
			covers.append(m)
	for m in covers:
		var tri := (m as MeshInstance3D).mesh.generate_triangle_mesh()
		if tri != null:
			_blockers.append({"mi": m, "tri": tri})


## Имена красимых мешей (по ним слой привязывается к мешам исполнения)
func mesh_names() -> Array[String]:
	var out: Array[String] = []
	for mi in meshes:
		out.append(str(mi.name))
	return out


## Имена мешей, не вошедших в группу
func skipped_names() -> Array[String]:
	var out: Array[String] = []
	for mi in skipped:
		out.append(str(mi.name))
	return out


func _build_viewport() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(res, res)
	_vp.transparent_bg = true
	_vp.disable_3d = true
	_vp.gui_disable_input = true
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_vp)
	var pos_img := Image.create_from_data(res, res, false, Image.FORMAT_RGBAF, (bake_info["pos"] as PackedFloat32Array).to_byte_array())
	var nrm_img := Image.create_from_data(res, res, false, Image.FORMAT_RGBAF, (bake_info["nrm"] as PackedFloat32Array).to_byte_array())
	var pos_tex := ImageTexture.create_from_image(pos_img)
	var nrm_tex := ImageTexture.create_from_image(nrm_img)
	bake_info.erase("pos")
	bake_info.erase("nrm")
	_stamp_mat = _make_stamp_material(STAMP_SHADER, pos_tex, nrm_tex)
	_erase_mat = _make_stamp_material(ERASE_SHADER, pos_tex, nrm_tex)
	_copy_mat = ShaderMaterial.new()
	_copy_mat.shader = COPY_SHADER
	_rect = ColorRect.new()
	_rect.size = Vector2(res, res)
	_rect.color = Color.WHITE
	_rect.material = _stamp_mat
	_vp.add_child(_rect)


func _make_stamp_material(shader: Shader, pos_tex: Texture2D, nrm_tex: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter("pos_tex", pos_tex)
	m.set_shader_parameter("nrm_tex", nrm_tex)
	m.set_shader_parameter("stamp_count", 0)
	return m


## Материал накладки с этим слоем (на каждую поверхность делается копия: у каждой своя цепочка next_pass)
func make_overlay() -> ShaderMaterial:
	return PaintLayers.make_overlay(texture)


# ==========================================
# ПОПАДАНИЕ И ШТАМПЫ
# ==========================================

## Луч камеры в точку мыши: ближайшая красимая часть. {position, normal, mesh} в пространстве опорного меша (target)
## или {}: луча нет, мимо, либо ближе красимой части стоит видимый меш, который не красится
func raycast(camera: Camera3D, mouse: Vector2) -> Dictionary:
	if _parts.is_empty() or target == null or not is_instance_valid(target):
		return {}
	var from := camera.project_ray_origin(mouse)
	var dir := camera.project_ray_normal(mouse)
	var best_d := INF
	var best_hit: Dictionary = {}
	var best_part: Dictionary = {}
	for part in _parts:
		var mi := part["mi"] as MeshInstance3D
		if not is_instance_valid(mi):
			continue
		var d := _ray_dist(part["tri"] as TriangleMesh, mi, from, dir)
		if d.is_empty() or d["dist"] >= best_d:
			continue
		best_d = d["dist"]
		best_hit = d
		best_part = part
	if best_hit.is_empty():
		return {}
	for b in _blockers:
		var bm := b["mi"] as MeshInstance3D
		if not is_instance_valid(bm) or not bm.is_visible_in_tree():
			continue
		var bd := _ray_dist(b["tri"] as TriangleMesh, bm, from, dir)
		if not bd.is_empty() and bd["dist"] < best_d - BLOCK_EPS:
			return {}
	var to_root: Transform3D = best_part["to_root"]
	var n := (to_root.basis.inverse().transposed() * (best_hit["normal"] as Vector3)).normalized()
	return {"position": to_root * (best_hit["position"] as Vector3), "normal": n, "mesh": best_part["mi"]}


## Попадание луча в меш: {position, normal} в локальных координатах меша и dist до точки в мире; {} при промахе
func _ray_dist(tri: TriangleMesh, mi: MeshInstance3D, from: Vector3, dir: Vector3) -> Dictionary:
	var xf := mi.global_transform
	var inv := xf.affine_inverse()
	var h := tri.intersect_ray(inv * from, (inv.basis * dir).normalized())
	if h.is_empty():
		return {}
	h["dist"] = from.distance_to(xf * (h["position"] as Vector3))
	return h


## Радиус кисти в единицах опорного меша по доле наибольшего габарита группы
func radius_for(size_frac: float) -> float:
	return size_ref * size_frac


func begin_stroke() -> void:
	_stroke_open = true


func end_stroke() -> void:
	_stroke_open = false


## Поставить штамп в очередь (рисуется в ближайшем кадре, до 32 штампов с одинаковыми параметрами за проход)
func stamp(local_pos: Vector3, local_normal: Vector3, radius: float, color: Color, flow: float, hardness: float, erase := false) -> void:
	if not is_built:
		return
	_queue.append({
		"p": Vector4(local_pos.x, local_pos.y, local_pos.z, radius),
		"n": Vector4(local_normal.x, local_normal.y, local_normal.z, 0.0),
		"color": color, "flow": flow, "hardness": hardness, "erase": erase,
	})


func has_pending() -> bool:
	return not _queue.is_empty() or _stroke_open or _dirty or _restoring


func _process(_delta: float) -> void:
	if not is_built or _restoring:
		return
	_flush()
	if _dirty and _queue.is_empty() and not _stroke_open:
		_idle_frames += 1
		if _idle_frames >= 2:
			_push_history()


func _flush() -> void:
	if _queue.is_empty():
		return
	var first: Dictionary = _queue[0]
	var mat := _erase_mat if first["erase"] else _stamp_mat
	var count := 0
	for q in _queue:
		if count >= MAX_STAMPS or not _same_params(q, first):
			break
		count += 1
	var centers: Array = []
	var normals: Array = []
	for i in MAX_STAMPS:
		if i < count:
			centers.append(_queue[i]["p"])
			normals.append(_queue[i]["n"])
		else:
			centers.append(Vector4.ZERO)
			normals.append(Vector4(0, 1, 0, 0))
	mat.set_shader_parameter("stamps", centers)
	mat.set_shader_parameter("stamp_nrm", normals)
	mat.set_shader_parameter("stamp_count", count)
	mat.set_shader_parameter("brush_color", first["color"])
	mat.set_shader_parameter("flow", first["flow"])
	mat.set_shader_parameter("hardness", first["hardness"])
	_rect.material = mat
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_queue = _queue.slice(count)
	_dirty = true
	_idle_frames = 0
	changed.emit()


func _same_params(a: Dictionary, b: Dictionary) -> bool:
	return a["erase"] == b["erase"] and a["flow"] == b["flow"] and a["hardness"] == b["hardness"] and a["color"] == b["color"]


# ==========================================
# ИСТОРИЯ
# ==========================================

func can_undo() -> bool:
	return _hist_index > 0


func can_redo() -> bool:
	return _hist_index < _history.size() - 1


## Шаг назад. false: нечего отменять или идёт штрих
func undo() -> bool:
	if not _prepare_history_step():
		return false
	if _hist_index <= 0:
		return false
	_hist_index -= 1
	_restore(_history[_hist_index])
	return true


func redo() -> bool:
	if not _prepare_history_step():
		return false
	if _hist_index >= _history.size() - 1:
		return false
	_hist_index += 1
	_restore(_history[_hist_index])
	return true


## Снимок текущего состояния, если есть несохранённые штампы. false: идёт штрих, ждём очередь или копирование
func _prepare_history_step() -> bool:
	if not is_built or _stroke_open or _restoring or not _queue.is_empty():
		return false
	if _dirty:
		_push_history()
	return true


## Очистить слой. Это тоже шаг истории
func clear() -> void:
	if not is_built:
		return
	_queue.clear()
	var blank := Image.create(res, res, false, Image.FORMAT_RGBA8)
	_copy_image(blank)
	_dirty = true
	_idle_frames = 2


func _push_history() -> void:
	_history.resize(_hist_index + 1)
	_history.append(_compress_layer())
	_hist_index = _history.size() - 1
	if _history.size() > HISTORY_LIMIT:
		_history.pop_front()
		_hist_index -= 1
	_dirty = false
	_idle_frames = 0


func _compress_layer() -> PackedByteArray:
	var raw := read_layer().get_data()
	_raw_size = raw.size()
	return raw.compress(FileAccess.COMPRESSION_FASTLZ)


func _restore(packed: PackedByteArray) -> void:
	var raw := packed.decompress(_raw_size, FileAccess.COMPRESSION_FASTLZ)
	_copy_image(Image.create_from_data(res, res, false, Image.FORMAT_RGBA8, raw))


## Копирует картинку в слой без смешивания (два кадра: отрисовка и возврат штампа)
func _copy_image(img: Image) -> void:
	_restoring = true
	_copy_mat.set_shader_parameter("src", ImageTexture.create_from_image(img))
	_rect.material = _copy_mat
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	await get_tree().process_frame
	_rect.material = _stamp_mat
	_restoring = false
	changed.emit()


## Ждёт, пока очередь штампов, штрих, отмена и снимок истории закончатся (перед чтением слоя для сохранения)
func wait_idle() -> void:
	while is_built and (not _queue.is_empty() or _stroke_open or _restoring or _dirty):
		await get_tree().process_frame


## Слой без краски (все байты нулевые: очистка и ластик умножают и цвет, и альфу). Читает с GPU
func is_empty() -> bool:
	var raw := read_layer().get_data()
	var zeros := PackedByteArray()
	zeros.resize(raw.size())
	return raw == zeros


## PNG слоя (RGBA8, цвет sRGB, умноженный на альфу). Читает с GPU: десятки миллисекунд
func to_png() -> PackedByteArray:
	return read_layer().save_png_to_buffer()


## Загружает PNG в слой (сохранённое исполнение) и начинает историю заново. false: файл не читается
func load_png(bytes: PackedByteArray) -> bool:
	if not is_built:
		return false
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return false
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if img.get_width() != res or img.get_height() != res:
		img.resize(res, res, Image.INTERPOLATE_BILINEAR)
	_queue.clear()
	await _copy_image(img)
	_history = [_compress_layer()]
	_hist_index = 0
	_dirty = false
	_idle_frames = 0
	return true


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


## Текущее содержимое слоя (RGBA8, премультиплицированный цвет). Читает с GPU: десятки миллисекунд
func read_layer() -> Image:
	var img := _vp.get_texture().get_image()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img
