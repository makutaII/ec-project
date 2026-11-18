extends Control

# XX claude-library (новый файл)
########################
## Room Studio. Просмотрщик комнат (ATTN_22 §22.5.5, шаг L1c)
########################
## Инструмент автора в дочернем окне Library. Слева список комнат из RoomCatalog: у комнат со сценой (RoomConfig.scene)
## выбор доступен, процедурные (сцены нет) серые. Центр: отдельный World3D с нейтральным светом и свободной камерой, в нём
## экземпляр сцены комнаты как есть (RoomBuilder и GFX игры не используются, слои RoomRoot.setup не применяются).
## Справа паспорт только для чтения. Свет и небо игры здесь не показываются: их проверяют в Observe.
## Правок паспорта и комнаты нет: это просмотр. Игру студия не трогает.
## Справа три вкладки (RM5): «Паспорт», «Объекты» (управляемые объекты сцены: RoomControlRegistry, свет и механизмы работают
## над экземпляром комнаты в окне студии, в игру и в сцену ничего не пишут), «Проверка» (отчёт по сцене).
## Два способа запуска (ATTN_25 §25.5):
##   - из Library поверх игры (LibraryScreen ставит embedded = true до входа в дерево);
##   - отдельно, F6 на room_studio.tscn: игры и RoomBuilder нет, пауза не включается, активации нет.
## «Оставить активной при выходе» (только embedded и Global.debug_mode): студия лишь сообщает выбранный id сигналом
## keep_room_changed, комнату меняет ModeController при закрытии Library (RoomBuilder.request_room, источник admin).

## Выбор для «Оставить активной»: id комнаты, пустое имя = выключено. Сообщается при каждой правке переключателя и выбора
signal keep_room_changed(id: StringName)

const StudioSettings := preload("res://core/library/icon_studio/studio_settings.gd")

const SETTINGS_PATH := "user://room_studio.cfg"
const HINT_TEXT := "ЛКМ: вращать   ·   Shift+ЛКМ, СКМ, ПКМ: сдвиг   ·   колесо: зум   ·   F: вписать"
const FOV := 40.0
const ORBIT_SPEED := 0.4
const PITCH_LIMIT := 89.0
const ZOOM_STEP := 1.12
const DIST_MIN := 20.0
const DIST_MAX := 4000.0
## Размеры мира в см (ATTN_14): комната около 5 м, поэтому дальняя плоскость далеко
const CAM_NEAR := 1.0
const CAM_FAR := 6000.0
const BG_COLOR := Color(0.16, 0.17, 0.19)

var settings: StudioSettings
## Открыта поверх игры (Library). Задаёт LibraryScreen до входа в дерево; при F6 false
var embedded := false
## Комната, оставленная включённым переключателем ранее (LibraryScreen хранит её, пока студия закрыта и открыта заново)
var keep_room: StringName = &""

var _entries: Array[Dictionary] = []    # {id, title, tip, dev_only, cfg: RoomConfig, has_scene: bool}
var _list: ItemList
var _info: Label
var _ceiling_check: CheckButton
var _table_check: CheckButton
var _keep_check: CheckButton
var _objects_box: VBoxContainer   # вкладка «Объекты»: строки управлений
var _check_label: Label           # вкладка «Проверка»
var _sync_btn: Button             # «Обновить паспорт из сцены» (только редактор, комната из .glb)
var _registry: RoomControlRegistry
var _active_label: Label
var _selected_id: StringName = &""   # выбранная в списке (у процедурной сцены нет, а выбрать её можно)
var _view_area: PanelContainer
var _vp: SubViewport
var _cam: Camera3D
var _stage: Node3D            # корень мира: комната и стол-ориентир
var _room: Node3D
var _table: MeshInstance3D
var _current_id: StringName = &""
var _yaw := 35.0
var _pitch := 25.0
var _dist := 700.0
var _pivot := Vector3.ZERO
var _drag_button := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	settings = StudioSettings.new()
	settings.name = "StudioSettings"
	settings.path = SETTINGS_PATH
	add_child(settings)

	_load_entries()
	_build_ui()
	_build_world()
	_fill_list()

	# Размеры контейнеров известны только после первого кадра раскладки
	await get_tree().process_frame
	_select_initial()


func _process(delta: float) -> void:
	# Механизмы комнаты ходят по времени (MechanismConfig.duration), пока их двигают ползунком
	if _registry != null and _registry.is_moving():
		_registry.tick(delta)


func _exit_tree() -> void:
	if settings:
		settings.flush()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and settings:
		settings.flush()


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_F and not k.ctrl_pressed:
		_fit()
		get_viewport().set_input_as_handled()


# ==========================================
# ДАННЫЕ
# ==========================================

## Все комнаты каталога; сцена есть у тех, чей паспорт из data/rooms ссылается на PackedScene
func _load_entries() -> void:
	_entries.clear()
	for e in RoomCatalog.entries():
		var cfg := RoomCatalog.make(e["id"])
		_entries.append({
			"id": e["id"],
			"title": e["title"],
			"tip": e["tip"],
			"dev_only": e["dev_only"],
			"cfg": cfg,
			"has_scene": cfg != null and cfg.scene != null,
		})


# ==========================================
# ИНТЕРФЕЙС
# ==========================================

func _build_ui() -> void:
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)
	# set_anchors_preset без offsets оставляет прежний (нулевой) размер, поэтому именно _and_offsets_
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 6)
	root.add_child(body)
	body.add_child(_build_left())
	body.add_child(_build_center())
	body.add_child(_build_right())

	var hint := Label.new()
	hint.text = HINT_TEXT
	hint.modulate = Color(1, 1, 1, 0.6)
	root.add_child(hint)


func _build_left() -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(280, 0)
	var v := VBoxContainer.new()
	p.add_child(v)
	var title := Label.new()
	title.text = "Комнаты"
	v.add_child(title)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_selected)
	v.add_child(_list)
	return p


func _build_center() -> Control:
	_view_area = PanelContainer.new()
	_view_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view_area.custom_minimum_size = Vector2(320, 240)
	_view_area.mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.1, 0.11)
	_view_area.add_theme_stylebox_override("panel", bg)
	_view_area.gui_input.connect(_on_view_input)
	return _view_area


func _build_right() -> Control:
	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(340, 0)
	tabs.add_child(_build_passport_tab())
	tabs.add_child(_build_objects_tab())
	tabs.add_child(_build_check_tab())
	return tabs


func _build_passport_tab() -> Control:
	var v := VBoxContainer.new()
	v.name = "Паспорт"
	v.add_theme_constant_override("separation", 6)
	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_info)
	v.add_child(HSeparator.new())
	_ceiling_check = CheckButton.new()
	_ceiling_check.text = "Потолок"
	_ceiling_check.tooltip_text = "Потолок скрыт по умолчанию: иначе внутрь комнаты не заглянуть"
	_ceiling_check.toggled.connect(func(_on: bool): _apply_toggles())
	v.add_child(_ceiling_check)
	_table_check = CheckButton.new()
	_table_check.text = "Стол-ориентир"
	_table_check.button_pressed = true
	_table_check.tooltip_text = "Столешница подмакетника по паспорту (table_top) на y = 0, только для масштаба: это не часть сцены комнаты"
	_table_check.toggled.connect(func(_on: bool): _apply_toggles())
	v.add_child(_table_check)
	_sync_btn = Button.new()
	_sync_btn.text = "Обновить паспорт из сцены"
	_sync_btn.tooltip_text = "Комната из .glb: числа сцены (floor_y, size, bounds, window, door, daylight) записываются в карточку data/rooms/cards/<id>.tres. Только из редактора"
	_sync_btn.visible = OS.has_feature("editor")
	_sync_btn.disabled = true
	_sync_btn.pressed.connect(_sync_card)
	v.add_child(_sync_btn)
	if _can_keep():
		v.add_child(HSeparator.new())
		_active_label = Label.new()
		v.add_child(_active_label)
		_keep_check = CheckButton.new()
		_keep_check.text = "Оставить активной при выходе"
		_keep_check.tooltip_text = "Просмотр игру не меняет. Включено: при закрытии Library выбранная комната станет активной в игре (если она другая). Только для админа (debug)"
		_keep_check.button_pressed = keep_room != &""
		_keep_check.toggled.connect(func(_on: bool): _emit_keep())
		v.add_child(_keep_check)
		_refresh_active_label()
	return v


func _build_objects_tab() -> Control:
	var sc := ScrollContainer.new()
	sc.name = "Объекты"
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_objects_box = VBoxContainer.new()
	_objects_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_objects_box.add_theme_constant_override("separation", 6)
	sc.add_child(_objects_box)
	return sc


func _build_check_tab() -> Control:
	var sc := ScrollContainer.new()
	sc.name = "Проверка"
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_check_label = Label.new()
	_check_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_check_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_check_label)
	return sc


func _fill_list() -> void:
	_list.clear()
	for e in _entries:
		var i := _list.add_item(String(e["title"]))
		if e["has_scene"]:
			_list.set_item_tooltip(i, String(e["tip"]))
			if e["dev_only"]:
				_list.set_item_text(i, "%s [dev]" % e["title"])
				_list.set_item_tooltip(i, "Тестовая комната (dev_only): игроку не показывается. %s" % e["tip"])
		else:
			_list.set_item_text(i, "%s (процедурная)" % e["title"])
			_list.set_item_custom_fg_color(i, Color(1, 1, 1, 0.55))
			_list.set_item_tooltip(i, "Процедурная комната: сцены нет, просмотр недоступен. Оставить активной можно (ATTN_25 §25.5)")


## Комната из keep_room, иначе последняя показанная, иначе первая со сценой
func _select_initial() -> void:
	var last := keep_room if keep_room != &"" else StringName(str(settings.get_value("state", "last_id", "")))
	var pick := -1
	for i in _entries.size():
		if _entries[i]["id"] == last:
			pick = i
			break
	if pick < 0:
		for i in _entries.size():
			if _entries[i]["has_scene"]:
				pick = i
				break
	if pick < 0:
		_info.text = "Нет комнат со сценой (карточки в data/rooms/cards/)."
		return
	_list.select(pick)
	_select(pick)


func _on_selected(i: int) -> void:
	_select(i)
	_emit_keep()


## Выбор в списке: комната со сценой показывается, у процедурной просмотра нет
func _select(i: int) -> void:
	if i < 0 or i >= _entries.size():
		return
	var e: Dictionary = _entries[i]
	_selected_id = e["id"]
	if e["has_scene"]:
		_show_room(i)
		return
	_clear_room()
	_info.text = "%s\n\nПроцедурная комната: сцены нет, просмотр недоступен.%s" % [_info_head(e),
			"\nОставить её активной в игре можно." if _can_keep() else ""]


# ==========================================
# ОСТАВИТЬ АКТИВНОЙ
# ==========================================

## Переключатель есть только над игрой и только админу
func _can_keep() -> bool:
	return embedded and Global.debug_mode


func _emit_keep() -> void:
	if _keep_check == null:
		return
	keep_room_changed.emit(_selected_id if _keep_check.button_pressed and _selected_id != &"" else &"")
	_refresh_active_label()


func _refresh_active_label() -> void:
	if _active_label == null:
		return
	var rb := get_tree().get_first_node_in_group(&"room_root") as RoomBuilder
	_active_label.text = "В игре сейчас: %s" % (String(rb.get_room_id()) if rb != null else "комнаты нет")


# ==========================================
# 3D-МИР
# ==========================================

func _build_world() -> void:
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view_area.add_child(svc)

	# Отдельный World3D: комната просмотра не видна игре и не видит её
	_vp = SubViewport.new()
	_vp.world_3d = World3D.new()
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.handle_input_locally = false
	svc.add_child(_vp)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.9, 0.92, 1.0)
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	_vp.add_child(we)

	# Нейтральный свет без теней: комнату надо видеть, а не оценивать
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)
	sun.light_energy = 0.6
	_vp.add_child(sun)

	_stage = Node3D.new()
	_stage.name = "Stage"
	_vp.add_child(_stage)

	_cam = Camera3D.new()
	_cam.fov = FOV
	_cam.near = CAM_NEAR
	_cam.far = CAM_FAR
	_vp.add_child(_cam)
	_cam.current = true
	_update_camera()


## Показать комнату i (только со сценой): прежняя комната освобождается
func _show_room(i: int) -> void:
	if i < 0 or i >= _entries.size():
		return
	var e: Dictionary = _entries[i]
	if not e["has_scene"]:
		return
	var cfg: RoomConfig = e["cfg"]
	_clear_room()
	_current_id = e["id"]
	settings.set_value("state", "last_id", String(_current_id))

	_room = RoomRoot.wrap(cfg.scene.instantiate())
	if _room == null:
		_info.text = "Не удалось создать сцену комнаты %s (корень не Node3D)." % e["id"]
		return
	_stage.add_child(_room)
	_build_table(cfg)
	_apply_toggles()
	_info.text = _info_text(e)
	_registry = RoomControlRegistry.collect(_room, String(e["id"]))   # внутри RoomRoot.import_glb: прокси и якоря .glb становятся объектами
	_rebuild_objects()
	_rebuild_check(e)
	_refresh_sync_btn()
	_fit()


## Числа сцены .glb -> файл карточки (только редактор) и копия паспорта в списке
func _sync_card() -> void:
	var rr := _room as RoomRoot
	var e := _entry(_current_id)
	if rr == null or rr.glb == null or not rr.glb.present or e.is_empty():
		return
	var path := "res://data/rooms/cards/%s.tres" % _current_id
	var res := load(path) as RoomConfig
	if res == null:
		_info.text = "%s\n\nКарточки %s нет: паспорт не обновлён." % [_info_head(e), path]
		return
	rr.glb.apply_to(res)
	var err := ResourceSaver.save(res, path)
	if err != OK:
		_info.text = "%s\n\nНе удалось записать %s (код %d)." % [_info_head(e), path, err]
		return
	rr.glb.apply_to(e["cfg"])
	_info.text = _info_text(e) + "\n\nПаспорт обновлён из сцены и записан в %s." % path
	_rebuild_check(e)


func _entry(id: StringName) -> Dictionary:
	for e in _entries:
		if e["id"] == id:
			return e
	return {}


func _refresh_sync_btn() -> void:
	if _sync_btn == null:
		return
	var rr := _room as RoomRoot
	var ok := rr != null and rr.glb != null and rr.glb.present
	_sync_btn.disabled = not ok


func _clear_room() -> void:
	_current_id = &""
	_registry = null
	if _sync_btn != null:
		_sync_btn.disabled = true
	_rebuild_objects()
	_rebuild_check({})
	if _room != null:
		_stage.remove_child(_room)
		_room.queue_free()
		_room = null
	if _table != null:
		_stage.remove_child(_table)
		_table.queue_free()
		_table = null


## Столешница подмакетника: масштаб и уровень y = 0. Сцена комнаты стол не содержит, его строит RoomBuilder
func _build_table(cfg: RoomConfig) -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(cfg.table_top.x, cfg.table_top_thickness, cfg.table_top.y)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.62, 0.5, 0.38)
	mesh.material = mat
	_table = MeshInstance3D.new()
	_table.name = "TableRef"
	_table.mesh = mesh
	_table.position = Vector3(0.0, -cfg.table_top_thickness * 0.5, 0.0)
	_stage.add_child(_table)


## Потолок и стол по галочкам. Потолок это ребёнок Ceiling у RoomRoot, у чужого корня потолка нет
func _apply_toggles() -> void:
	if _table != null:
		_table.visible = _table_check.button_pressed
	var rr := _room as RoomRoot
	if rr == null:
		return
	var c := rr.get_ceiling()
	if c != null:
		c.visible = _ceiling_check.button_pressed


func _info_head(e: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("%s" % e["title"])
	lines.append("id: %s%s" % [e["id"], "  (dev_only)" if e["dev_only"] else ""])
	if String(e["tip"]) != "":
		lines.append(String(e["tip"]))
	return "\n".join(lines)


func _info_text(e: Dictionary) -> String:
	var cfg: RoomConfig = e["cfg"]
	var lines := PackedStringArray()
	lines.append(_info_head(e))
	lines.append("")
	lines.append("Размер, см: %.0f × %.0f × %.0f" % [cfg.size.x, cfg.size.y, cfg.size.z])
	lines.append("Уровень пола (floor_y): %.0f" % cfg.floor_y)
	lines.append("Форма: %s" % cfg.shape)
	lines.append("Дневной свет: %s" % ("да" if cfg.daylight else "нет"))
	lines.append("Ambient ×: %.2f" % cfg.ambient_mul)
	lines.append("Столешница, см: %.0f × %.0f" % [cfg.table_top.x, cfg.table_top.y])
	lines.append("Ламп в сцене: %d" % _count_lights(_room))
	return "\n".join(lines)


func _count_lights(n: Node) -> int:
	if n == null:
		return 0
	var c := 1 if n is Light3D else 0
	for ch in n.get_children():
		c += _count_lights(ch)
	return c


# ==========================================
# ОБЪЕКТЫ И ПРОВЕРКА
# ==========================================

## Вкладка «Объекты»: по строке на управление. TOGGLE переключатель, SLIDER и MECH ползунок 0..1
func _rebuild_objects() -> void:
	if _objects_box == null:
		return
	for c in _objects_box.get_children():
		_objects_box.remove_child(c)
		c.queue_free()
	if _registry == null:
		_add_hint("Комната не выбрана или без сцены: управляемых объектов нет.")
		return
	if _registry.defs.is_empty():
		_add_hint("В сцене нет управляемых объектов. Метка RoomControl на лампе, узле или плеере анимации даёт здесь строку (ATTN_25 §25.6).")
	var reset := Button.new()
	reset.text = "Всё в начальное состояние"
	reset.pressed.connect(func() -> void:
		if _registry != null:
			_registry.reset()
		_rebuild_objects.call_deferred())
	_objects_box.add_child(reset)
	for d in _registry.defs:
		_objects_box.add_child(_object_row(d))
	if not _registry.warnings.is_empty():
		_add_hint("Замечания:\n- " + "\n- ".join(_registry.warnings))


func _add_hint(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.modulate = Color(1, 1, 1, 0.7)
	_objects_box.add_child(l)


func _object_row(d: RoomControlDef) -> Control:
	var box := VBoxContainer.new()
	var tag := "Observe" if d.scope == RoomControl.Scope.OBSERVE else "студия"
	var cnt := " ×%d" % d.nodes.size() if d.nodes.size() > 1 else ""
	var tip := "id: %s, узлов: %d, в Observe: %s" % [d.id, d.nodes.size(), "да" if d.scope == RoomControl.Scope.OBSERVE else "нет"]
	if d.kind == RoomControl.Kind.TOGGLE:
		var cb := CheckButton.new()
		cb.text = "%s%s  [%s]" % [d.display_title(), cnt, tag]
		cb.tooltip_text = tip
		cb.button_pressed = d.value > 0.0
		cb.toggled.connect(func(on: bool) -> void: d.set_value(1.0 if on else 0.0))
		box.add_child(cb)
		return box
	var l := Label.new()
	l.text = "%s%s  [%s]" % [d.display_title(), cnt, tag]
	l.tooltip_text = tip
	box.add_child(l)
	var sl := HSlider.new()
	sl.min_value = 0.0
	sl.max_value = 1.0
	sl.step = 0.01
	sl.value = d.value
	sl.custom_minimum_size = Vector2(0, 22)
	sl.tooltip_text = tip
	# Свет: сразу. Механизм: цель, к ней идёт _process по duration
	sl.value_changed.connect(func(v: float) -> void: d.set_value(v, d.kind != RoomControl.Kind.MECH))
	box.add_child(sl)
	return box


## Вкладка «Проверка»: сводка по сцене и замечания реестра. Те же правила, что у glb_preflight.py --kind room, добавит RM7
func _rebuild_check(e: Dictionary) -> void:
	if _check_label == null:
		return
	if _room == null or e.is_empty():
		_check_label.text = "Комната не выбрана или без сцены."
		return
	var lines := PackedStringArray()
	lines.append("Сцена: %s" % (e["cfg"] as RoomConfig).scene.resource_path)
	lines.append("Корень: %s%s" % [_room.get_class() if _room.get_script() == null else String(_room.get_script().get_global_name()),
			"" if _room is RoomRoot else "  (ожидается RoomRoot)"])
	lines.append("")
	lines.append("Треугольников по группам корня:")
	var total := 0
	for ch in _room.get_children():
		var tri := _triangles(ch)
		total += tri
		lines.append("  %s: %d" % [ch.name, tri])
	lines.append("  всего: %d" % total)
	lines.append("")
	lines.append("Ламп (Light3D): %d" % _count_lights(_room))
	var n_ctl := _registry.defs.size() if _registry != null else 0
	lines.append("Управляемых объектов: %d (Observe: %d)" % [n_ctl,
			_registry.for_scope(RoomControl.Scope.OBSERVE).size() if _registry != null else 0])
	var rr := _room as RoomRoot
	if rr != null and rr.glb != null and rr.glb.present and e.has("cfg"):
		lines.append("")
		lines.append("Сцена из .glb: ламп создано %d, лампочек %d, группы: %s" % [rr.glb.lights.size(), rr.glb.bulbs.size(),
				", ".join(PackedStringArray(rr.glb.groups.keys().map(func(k): return String(k))))])
		var df := rr.glb.diff(e["cfg"] as RoomConfig)
		lines.append("Паспорт и сцена: %s" % ("числа сходятся" if df.is_empty() else "расходятся (кнопка «Обновить паспорт из сцены» на вкладке «Паспорт»)"))
		for d in df:
			lines.append("  - " + d)
	if _registry != null and not _registry.warnings.is_empty():
		lines.append("")
		lines.append("Замечания:")
		for w in _registry.warnings:
			lines.append("  - " + w)
	elif _registry != null:
		lines.append("")
		lines.append("Замечаний нет.")
	_check_label.text = "\n".join(lines)


func _triangles(n: Node) -> int:
	var t := 0
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		t += int((n as MeshInstance3D).mesh.get_faces().size() / 3.0)
	for c in n.get_children():
		t += _triangles(c)
	return t


# ==========================================
# КАМЕРА
# ==========================================

## Границы сцены по мешам (в мировых координатах просмотра); без мешей берём размер из паспорта
func _room_bounds() -> AABB:
	var out := AABB()
	var have := false
	if _room != null:
		for mi in _meshes(_room):
			var b: AABB = mi.global_transform * mi.get_aabb()
			if have:
				out = out.merge(b)
			else:
				out = b
				have = true
	if _table != null and _table.visible:
		var tb: AABB = _table.global_transform * _table.get_aabb()
		out = out.merge(tb) if have else tb
		have = true
	if not have:
		out = AABB(Vector3(-200, -50, -150), Vector3(400, 250, 300))
	return out


func _meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null and (n as MeshInstance3D).is_visible_in_tree():
		out.append(n as MeshInstance3D)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out


func _fit() -> void:
	var box := _room_bounds()
	_pivot = box.get_center()
	var radius := maxf(box.size.length() * 0.5, 1.0)
	_dist = clampf(radius / sin(deg_to_rad(FOV) * 0.5) * 1.05, DIST_MIN, DIST_MAX)
	_update_camera()


func _update_camera() -> void:
	if _cam == null:
		return
	var p := deg_to_rad(_pitch)
	var y := deg_to_rad(_yaw)
	var dir := Vector3(sin(y) * cos(p), sin(p), cos(y) * cos(p))
	_cam.look_at_from_position(_pivot + dir * _dist, _pivot, Vector3.UP)


func _on_view_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null:
		if mb.pressed:
			match mb.button_index:
				MOUSE_BUTTON_WHEEL_UP:
					_dist = clampf(_dist / ZOOM_STEP, DIST_MIN, DIST_MAX)
				MOUSE_BUTTON_WHEEL_DOWN:
					_dist = clampf(_dist * ZOOM_STEP, DIST_MIN, DIST_MAX)
				_:
					_drag_button = mb.button_index
		elif mb.button_index == _drag_button:
			_drag_button = 0
		_update_camera()
		return
	var mm := event as InputEventMouseMotion
	if mm == null or _drag_button == 0:
		return
	var pan := _drag_button == MOUSE_BUTTON_MIDDLE or _drag_button == MOUSE_BUTTON_RIGHT \
			or (_drag_button == MOUSE_BUTTON_LEFT and mm.shift_pressed)
	if pan:
		# Пиксели экрана в сантиметры мира на расстоянии до точки обзора
		var k := 2.0 * _dist * tan(deg_to_rad(FOV) * 0.5) / maxf(float(_vp.size.y), 1.0)
		var basis := _cam.global_transform.basis
		_pivot += (-basis.x * mm.relative.x + basis.y * mm.relative.y) * k
	elif _drag_button == MOUSE_BUTTON_LEFT:
		_yaw -= mm.relative.x * ORBIT_SPEED
		_pitch = clampf(_pitch + mm.relative.y * ORBIT_SPEED, -PITCH_LIMIT, PITCH_LIMIT)
	_update_camera()
