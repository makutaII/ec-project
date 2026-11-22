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
const RELIEF_SHADER := preload("res://core/library/paint/relief_bake.gdshader")
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
## Карта рельефа для сухой кисти и смывки (строится по требованию, build_relief): готова ли и на какой ширине перехода
## Размер текселя слоя в единицах опорного меша (по площади поверхности и покрытым текселям): нужен декалям для мипмапа
var texel_world := 0.01
var relief_ready := false
var relief_width := 0.0
## Маска (скотч и трафарет): вторая карта в том же пространстве UV2, A это насколько тексель закрыт от краски.
## Маска временная: в исполнение и в игру не попадает. Рисуется теми же штампами (opts.mask), стирается ластиком маски
var mask_used := false
var _mask_vp: SubViewport
var _mask_rect: ColorRect
var _mask_stamp_mat: ShaderMaterial
var _mask_erase_mat: ShaderMaterial
var _relief_vp: SubViewport
var _relief_src: Array = []         # красимые поверхности: [{uv2, uv1, idx, texture, scale, offset}]
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
	_relief_src.clear()
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
		for surf in entries[i]["surfaces"]:
			var uv1: PackedVector2Array = surf.get("uv1", PackedVector2Array())
			if uv1.size() != (surf["uv2"] as PackedVector2Array).size():
				continue
			var info := PaintBake.albedo_info(mi.get_active_material(int(surf["surface"])))
			_relief_src.append({"uv2": surf["uv2"], "uv1": uv1, "idx": surf["idx"], "texture": info["texture"],
				"scale": info["scale"], "offset": info["offset"]})
		var tri := mi.mesh.generate_triangle_mesh()
		if tri != null:
			_parts.append({"mi": mi, "tri": tri, "to_root": xf})
		var bb: AABB = xf * mi.mesh.get_aabb()
		box = bb if not has_box else box.merge(bb)
		has_box = true
	size_ref = maxf(box.size.x, maxf(box.size.y, box.size.z))
	if size_ref <= 0.0:
		size_ref = 1.0
	texel_world = sqrt(_surface_area(entries, included) / maxf(float(bake_info.get("covered", 1)), 1.0))
	if texel_world <= 0.0 or is_nan(texel_world):
		texel_world = size_ref / float(res)
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


## Строит карту рельефа (контраст яркости базовой текстуры с окружением, радиус width_px пикселей слоя) и ждёт кадры.
## Повторный вызов с другой шириной перестраивает карту. Без текстуры у материалов карта нулевая (красить нечем)
func build_relief(width_px: float) -> void:
	if not is_built:
		return
	relief_ready = false
	if _relief_vp != null:
		_relief_vp.queue_free()
	_relief_vp = SubViewport.new()
	_relief_vp.size = Vector2i(res, res)
	_relief_vp.transparent_bg = true
	_relief_vp.disable_3d = true
	_relief_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_relief_vp)
	for src in _relief_src:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		var v2 := PackedVector2Array()
		for uv in (src["uv2"] as PackedVector2Array):
			v2.append(uv * float(res))
		arrays[Mesh.ARRAY_VERTEX] = v2
		arrays[Mesh.ARRAY_TEX_UV] = src["uv1"]
		if not (src["idx"] as PackedInt32Array).is_empty():
			arrays[Mesh.ARRAY_INDEX] = src["idx"]
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat := ShaderMaterial.new()
		mat.shader = RELIEF_SHADER
		var tex: Texture2D = src["texture"]
		mat.set_shader_parameter("has_tex", tex != null)
		mat.set_shader_parameter("albedo_tex", tex)
		mat.set_shader_parameter("uv_scale", src["scale"])
		mat.set_shader_parameter("uv_offset", src["offset"])
		mat.set_shader_parameter("width", maxf(width_px, 0.5))
		var node := MeshInstance2D.new()
		node.mesh = mesh
		node.material = mat
		_relief_vp.add_child(node)
	await _settle()
	await get_tree().process_frame
	relief_width = width_px
	relief_ready = true


## Площадь поверхности красимых мешей в единицах опорного меша
func _surface_area(entries: Array, included: PackedInt32Array) -> float:
	var area := 0.0
	for i in included:
		var xf: Transform3D = entries[i]["xform"]
		var k := pow(absf(xf.basis.determinant()), 2.0 / 3.0)
		for surf in entries[i]["surfaces"]:
			var vs: PackedVector3Array = surf["verts"]
			var idx: PackedInt32Array = surf["idx"]
			if idx.is_empty():
				idx = PackedInt32Array(range(vs.size()))
			for t in range(0, idx.size() - 2, 3):
				var a := vs[idx[t]]
				area += (vs[idx[t + 1]] - a).cross(vs[idx[t + 2]] - a).length() * 0.5 * k
	return area


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
	_vp.use_hdr_2d = true      # слой 16 бит на канал: в 8 битах малый поток залипал, а цвет на мягком крае темнел
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
	# карта маски: те же карты позиций и нормалей, свои материалы штампа и ластика (mask_on у них выключен)
	_mask_vp = SubViewport.new()
	_mask_vp.size = Vector2i(res, res)
	_mask_vp.transparent_bg = true
	_mask_vp.use_hdr_2d = true
	_mask_vp.disable_3d = true
	_mask_vp.gui_disable_input = true
	_mask_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	_mask_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_mask_vp)
	_mask_stamp_mat = _make_stamp_material(STAMP_SHADER, pos_tex, nrm_tex)
	_mask_erase_mat = _make_stamp_material(ERASE_SHADER, pos_tex, nrm_tex)
	_mask_rect = ColorRect.new()
	_mask_rect.size = Vector2(res, res)
	_mask_rect.color = Color.WHITE
	_mask_rect.material = _mask_stamp_mat
	_mask_vp.add_child(_mask_rect)


func _make_stamp_material(shader: Shader, pos_tex: Texture2D, nrm_tex: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter("pos_tex", pos_tex)
	m.set_shader_parameter("nrm_tex", nrm_tex)
	m.set_shader_parameter("stamp_count", 0)
	m.set_shader_parameter("tip_plain", true)
	return m


## Материал накладки с этим слоем (на каждую поверхность делается копия: у каждой своя цепочка next_pass)
func make_overlay() -> ShaderMaterial:
	var m := PaintLayers.make_overlay(texture)
	if _mask_vp != null:
		m.set_shader_parameter("mask_tex", _mask_vp.get_texture())      # маска видна красным только в Library (в игре у накладки её нет)
		m.set_shader_parameter("mask_show", true)
	return m


## Убрать маску целиком и все ещё не нарисованные штампы маски
func clear_mask() -> void:
	if not is_built:
		return
	_queue = _queue.filter(func(q: Dictionary) -> bool: return not q["mask"])
	_mask_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	_mask_stamp_mat.set_shader_parameter("stamp_count", 0)
	_mask_rect.material = _mask_stamp_mat
	_mask_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	mask_used = false


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


## Поставить штамп в очередь (рисуется в ближайшем кадре, до 32 штампов с одинаковыми параметрами за проход).
## opts (PaintBrushes.stamp_opts): tip (id текстуры конца или ""), shape ("round" или "box"), box (Vector2, полуразмеры конца
## в долях радиуса), tan (направление конца в касательной плоскости), load (запас краски 0..1), dry (сила сухой кисти),
## sample (id образца из PaintSamples или ""), sample_size (повтор образца в долях габарита группы мешей),
## sample_shift (Vector2, сдвиг образца в тайлах: свой у каждого мазка),
## relief (0 нет, 1 красить выступы и светлые кромки, -1 впадины и тёмные тени), relief_sens (чувствительность);
## mask (true: штамп пишет в карту маски, а не в слой краски; erase снимает маску), stencil (картинка decal как трафарет:
## закрывает рисунок или фон, stencil_ink: true рисунок), у трафарета tint и цвет не нужны;
## decal (id декали из PaintDecals или ""), decal_mirror, decal_tint (умножать на цвет палитры); у декали tan это
## направление «вправо» по картинке, radius полуразмер большей стороны, одна декаль на пачку;
## со relief не равным 0 штампы игнорируются, пока карта рельефа не построена (build_relief)
func stamp(local_pos: Vector3, local_normal: Vector3, radius: float, color: Color, flow: float, hardness: float, erase := false, opts: Dictionary = {}) -> void:
	if not is_built:
		return
	var relief_dir := signf(float(opts.get("relief", 0.0)))
	if relief_dir != 0.0 and not relief_ready:
		return
	var n := local_normal.normalized()
	var tan_dir: Vector3 = opts.get("tan", Vector3.ZERO)
	tan_dir = tan_dir - n * tan_dir.dot(n)
	if tan_dir.length() < 0.00001:
		tan_dir = PaintBrushes.tangent(n, "fixed", Vector3.ZERO, null)
	tan_dir = tan_dir.normalized()
	_queue.append({
		"p": Vector4(local_pos.x, local_pos.y, local_pos.z, radius),
		"n": Vector4(n.x, n.y, n.z, 0.0),
		"t": Vector4(tan_dir.x, tan_dir.y, tan_dir.z, clampf(float(opts.get("load", 1.0)), 0.0, 1.0)),
		"color": color, "flow": flow, "hardness": hardness, "erase": erase,
		"tip": str(opts.get("tip", "")), "shape": 1 if str(opts.get("shape", "round")) == "box" else 0,
		"box": opts.get("box", Vector2.ONE), "dry": float(opts.get("dry", 0.0)),
		"sample": str(opts.get("sample", "")), "ssize": float(opts.get("sample_size", 0.25)),
		"relief": relief_dir, "rsens": float(opts.get("relief_sens", 1.0)),
		"sshift": opts.get("sample_shift", Vector2.ZERO),
		"decal": str(opts.get("decal", "")), "dmirror": bool(opts.get("decal_mirror", false)),
		"dtint": bool(opts.get("decal_tint", true)),
		"mask": bool(opts.get("mask", false)), "stencil": bool(opts.get("stencil", false)),
		"sink": bool(opts.get("stencil_ink", true)),
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
	var is_mask: bool = first["mask"]
	var mat: ShaderMaterial
	if is_mask:
		mat = _mask_erase_mat if first["erase"] else _mask_stamp_mat
	else:
		mat = _erase_mat if first["erase"] else _stamp_mat
	var count := 0
	for q in _queue:
		# первый штамп входит всегда (декаль не равна даже себе: она одна на пачку), остальные только с теми же параметрами
		if count >= MAX_STAMPS or (count > 0 and not _same_params(q, first)):
			break
		count += 1
	var centers: Array = []
	var normals: Array = []
	var tangents: Array = []
	for i in MAX_STAMPS:
		if i < count:
			centers.append(_queue[i]["p"])
			normals.append(_queue[i]["n"])
			tangents.append(_queue[i]["t"])
		else:
			centers.append(Vector4.ZERO)
			normals.append(Vector4(0, 1, 0, 0))
			tangents.append(Vector4(1, 0, 0, 1))
	mat.set_shader_parameter("stamps", centers)
	mat.set_shader_parameter("stamp_nrm", normals)
	mat.set_shader_parameter("stamp_tan", tangents)
	mat.set_shader_parameter("stamp_count", count)
	var tip_id: String = first["tip"]
	var box: Vector2 = first["box"]
	mat.set_shader_parameter("tip_tex", PaintTips.texture(tip_id))
	mat.set_shader_parameter("tip_textured", PaintTips.has(tip_id))
	mat.set_shader_parameter("tip_shape", first["shape"])
	mat.set_shader_parameter("tip_box", box)
	mat.set_shader_parameter("tip_plain", first["shape"] == 0 and not PaintTips.has(tip_id) and box.is_equal_approx(Vector2.ONE))
	mat.set_shader_parameter("dry", first["dry"])
	if mat == _stamp_mat or mat == _mask_stamp_mat:
		var sample_id: String = first["sample"]
		mat.set_shader_parameter("sample_on", PaintSamples.has(sample_id))
		mat.set_shader_parameter("sample_tex", PaintSamples.texture(sample_id))
		mat.set_shader_parameter("sample_scale", 1.0 / maxf(size_ref * float(first["ssize"]), 0.0001))
		mat.set_shader_parameter("sample_shift", first["sshift"])
		var decal_id: String = first["decal"]
		var decal_tex: Texture2D = PaintDecals.texture(decal_id) if decal_id != "" else null
		mat.set_shader_parameter("decal_on", decal_tex != null)
		if decal_tex != null:
			var dbox := PaintDecals.aspect_box(decal_id)
			var dpx := 2.0 * float((first["p"] as Vector4).w) / maxf(texel_world, 0.000001) * maxf(dbox.x, dbox.y)
			var big := float(maxi(decal_tex.get_width(), decal_tex.get_height()))
			mat.set_shader_parameter("decal_tex", decal_tex)
			mat.set_shader_parameter("decal_box", dbox)
			mat.set_shader_parameter("decal_mirror", first["dmirror"])
			mat.set_shader_parameter("decal_tint", first["dtint"])
			mat.set_shader_parameter("decal_lod", maxf(log(big / maxf(dpx, 1.0)) / log(2.0), 0.0))
			mat.set_shader_parameter("decal_stencil", first["stencil"])
			mat.set_shader_parameter("decal_cover_ink", first["sink"])
			mat.set_shader_parameter("decal_has_alpha", PaintDecals.has_alpha(decal_id))
		var on: bool = float(first["relief"]) != 0.0 and relief_ready and _relief_vp != null
		mat.set_shader_parameter("relief_on", on)
		if on:
			mat.set_shader_parameter("relief_tex", _relief_vp.get_texture())
			mat.set_shader_parameter("relief_dir", first["relief"])
			mat.set_shader_parameter("relief_sens", first["rsens"])
	mat.set_shader_parameter("brush_color", first["color"])
	mat.set_shader_parameter("flow", first["flow"])
	mat.set_shader_parameter("hardness", first["hardness"])
	if is_mask:
		# штамп маски: в карту маски, без истории слоя краски (отмены у маски нет: «Открыть» и «Очистить маску»)
		_mask_rect.material = mat
		_mask_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		if not first["erase"]:
			mask_used = true
		_queue = _queue.slice(count)
		return
	mat.set_shader_parameter("mask_on", mask_used)
	mat.set_shader_parameter("mask_tex", _mask_vp.get_texture())
	_rect.material = mat
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_queue = _queue.slice(count)
	_dirty = true
	_idle_frames = 0
	changed.emit()


func _same_params(a: Dictionary, b: Dictionary) -> bool:
	return a["erase"] == b["erase"] and a["flow"] == b["flow"] and a["hardness"] == b["hardness"] and a["color"] == b["color"] \
		and a["tip"] == b["tip"] and a["shape"] == b["shape"] and a["box"] == b["box"] and a["dry"] == b["dry"] \
		and a["sample"] == b["sample"] and a["ssize"] == b["ssize"] and a["relief"] == b["relief"] and a["rsens"] == b["rsens"] and a["sshift"] == b["sshift"] \
		and a["decal"] == "" and b["decal"] == "" and a["mask"] == b["mask"] and a["stencil"] == b["stencil"] and a["sink"] == b["sink"]


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
