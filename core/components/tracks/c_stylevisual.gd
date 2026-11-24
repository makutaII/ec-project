class_name C_StyleVisual extends C_TrackVisual

# XX claude-terra (новый файл)
###################################
## Визуал жёсткого трака (прямая/дуга/пандус) из TrackStyle. Сцены из Blender нет: ноды
## строятся в коде один раз (форма не меняется после создания), тем же каркасом, что у
## C_FlexVisual (TrackMeshBuilder.build_skeleton) — Mesh, Sleepers, Ballast Area3D,
## HeadStaticBody3D, — поэтому C_Path / C_Blockable / C_Socket работают по тем же правилам.
###################################
## Создаётся через StyleVisualSetting, который добавляет C_Path ДО этого компонента:
## на on_entity_ready() curve/path_node у C_Path уже готовы (генерируются в его собственном
## on_entity_ready, которая по порядку детей идёт раньше). Высоту поверхности катания
## C_Path.head_height() получает отсюда же (style.head_height()), раньше, чем успевает
## закэшировать запасное значение (это безопасно: внутренняя проверка в C_Path сейчас
## не имеет побочных эффектов).
## В отличие от flex: форма строится один раз, без пула/пересборки и без _process.

## Задаёт StyleVisualSetting. null = TrackStyle по умолчанию (балласт, 0.85)
var style: TrackStyle

const CLIP_S := 2.2      # вдоль кривой от начала, как раньше (z = -2.2)
const CLIP_GAP := 0.6    # от края основания до оси клипа (ширина клипа 1.0 -> зазор 0.1)
const CLIP_LIFT := 0.3   # половина высоты коробки клипа (0.6), чтобы стояла на основании

var mesh_node: MeshInstance3D
var sleepers: MultiMeshInstance3D
var ballast: Area3D
var head: StaticBody3D


## Базовый C_Visual.on_added инстанцирует сцену; здесь сцены нет, каркас строится кодом
func on_added() -> void:
	if style == null:
		style = TrackStyle.new()
	rail_surface_index = style.rail_surface_index()

	# XX claude-car CS1: путь уже добавлен StyleVisualSetting, слой основания берём у него (у рельсов tracks, у дороги roads)
	var own_path := get_comp(C_Path) as C_Path
	var sk := TrackMeshBuilder.build_skeleton(style, "StyleTrack", own_path.solid_layer_bit() if own_path else (1 << 2))
	mesh_node = sk.mesh_node
	sleepers = sk.sleepers
	ballast = sk.ballast
	head = sk.head
	instance = sk.root

	entity.add_child(instance)
	parts = PartRegistry.build(instance)
	_collect_meshes()
	_on_instance_ready()   # C_TrackVisual: area_nodes, static_node


## C_Path (StyleVisualSetting создаёт его первым) уже сгенерировал кривую к этому моменту
func on_entity_ready() -> void:
	var path := get_comp(C_Path) as C_Path
	if not path or not path.curve:
		return
	path.set_head_height(style.head_height())

	var curve := path.curve
	var L := curve.get_baked_length()
	if L < 0.01:
		return

	mesh_node.mesh = TrackMeshBuilder.build_mesh(style, curve, L, false)
	TrackMeshBuilder.place_sleepers(sleepers.multimesh, style, curve, L)
	_build_collision(curve, L)


## Пандус: подъём уже в кривой C_Path (rise), меш строится по ней вместе с наклоном репера.
## Базовый C_TrackVisual по on_slope_changed ещё и наклонил бы instance (так делают сцены из Blender,
## они прямые): получился бы двойной наклон. Поэтому здесь событие игнорируем
func on_slope_changed(_data: Dictionary) -> void:
	pass


## Клип питания: сбоку от основания (ширина из стиля, а не константа сцены), на расстоянии
## CLIP_S от начала вдоль кривой, повёрнут по реперу (на пандусе стоит вдоль уклона).
## Ставим на основание (низ клипа = низ трака), а не на поверхность катания: клип стоит рядом с треком
func clip_transform() -> Transform3D:
	var path := get_comp(C_Path) as C_Path
	if style == null or path == null or path.curve == null:
		return super()
	var L := path.curve.get_baked_length()
	if L < 0.01:
		return super()
	var f := TrackMeshBuilder.frame(path.curve, minf(CLIP_S, L), L)
	var b := Basis(f.r, f.u, f.r.cross(f.u))
	var x := style.collision_width * 0.5 + CLIP_GAP
	return Transform3D(b, f.p + f.r * x + f.u * CLIP_LIFT)


func _set_overlay(mat: Material) -> void:
	super(mat)
	if sleepers:
		sleepers.material_overlay = mat


## Форма не меняется после создания: заглушки убираем и строим боксы один раз
func _build_collision(curve: Curve3D, L: float) -> void:
	ballast.get_child(0).queue_free()   # заглушка из build_skeleton
	head.get_child(0).queue_free()

	var cuts := TrackMeshBuilder.collision_cuts(curve, L, false, true)   # прямая: одна коллизия
	for i in cuts.size() - 1:
		var bx := TrackMeshBuilder.segment_boxes(style, curve, L, cuts[i], cuts[i + 1])
		var cb := TrackMeshBuilder.new_shape(bx.ballast_size)
		cb.transform = bx.ballast_xf
		ballast.add_child(cb)

		var hb := TrackMeshBuilder.new_shape(bx.ballast_size)
		hb.transform = bx.ballast_xf
		head.add_child(hb)
		var hl := TrackMeshBuilder.new_shape(bx.rail_size)
		hl.transform = bx.rail_l_xf
		head.add_child(hl)
		var hr := TrackMeshBuilder.new_shape(bx.rail_size)
		hr.transform = bx.rail_r_xf
		head.add_child(hr)


## Стиль для подгонки полос слоя питания под UV рельса (тайл, поворот)
func _power_style() -> TrackStyle:
	return style


## U13 (D13): секция вкладки Visual в InfoPanel: стиль трака из набора проекта (ATTN_17 §17.13).
## Стиль-сцена budget у формы без сцены строится запасным стилем, об этом сказано в строке.
## Стиль, зафиксированный в самом объекте, id в набор не пишет
func get_info_sections() -> Array[InfoSection]:
	return [InfoSection.make("Стиль трака", [
		InfoSection.label("Стиль", _style_title),
		InfoSection.label("Высота рельса", func() -> String: return "%.2f" % style.head_height() if style != null else "-"),
		InfoSection.label("Сцена Blender", func() -> String: return "да" if style != null and style.use_scene else "нет"),
	])]


func _style_title() -> String:
	if entity != null and entity.style_id != &"":
		var st := TSM.get_style(entity.style_id)
		if style != null and st != null and st.use_scene:
			return "%s (нет сцены, как %s)" % [entity.style_id, style.id]
		return String(entity.style_id)
	if style != null:
		return "%s (в объекте)" % style.id
	return "-"
