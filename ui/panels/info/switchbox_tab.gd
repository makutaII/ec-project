class_name InfoSwitchboxTab extends InfoTab

###########################
## Блок «Коммутатор» во вкладке «Настройки» (ATTN_10 D5, U5a.4)
###########################
## Встроен в InfoSettingsTab (embed). У селектора блоков, реверсора и предохранителя: положение, замена предохранителя, лимит тока,
## «Автопроводка» устройства, список игровых задач с проверкой условий (PowerTasks).

var _state: Label
var _pos_box: HBoxContainer
var _fuse_box: VBoxContainer
var _limit: SpinBox
var _replace: Button
var _tasks: Label
var _syncing := false


func _setup() -> void:
	var box := make_page("Коммутатор")
	block_heading(box, "Коммутатор")
	_state = Label.new()
	_state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_state.custom_minimum_size = Vector2(120, 0)
	box.add_child(_state)
	_pos_box = HBoxContainer.new()
	box.add_child(_pos_box)

	_fuse_box = VBoxContainer.new()
	box.add_child(_fuse_box)
	var row := HBoxContainer.new()
	_fuse_box.add_child(row)
	var l := Label.new()
	l.text = "Лимит, А"
	row.add_child(l)
	_limit = SpinBox.new()
	_limit.min_value = 0.1
	_limit.max_value = 10.0
	_limit.step = 0.1
	_limit.value_changed.connect(_on_limit_changed)
	row.add_child(_limit)
	_replace = Button.new()
	_replace.text = "Заменить предохранитель"
	_replace.pressed.connect(_on_replace)
	_fuse_box.add_child(_replace)

	var auto_btn := Button.new()
	auto_btn.text = "Автопроводка (пульт → устройство → клипы)"
	auto_btn.pressed.connect(_on_autowire)
	box.add_child(auto_btn)

	box.add_child(HSeparator.new())
	block_heading(box, "Задачи")
	_tasks = Label.new()
	_tasks.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tasks.custom_minimum_size = Vector2(120, 0)
	box.add_child(_tasks)


func can_show(entity: Entity) -> bool:
	return entity != null and not entity.has_comp(C_Ghost) and entity.has_comp(C_PowerDevice)


func _on_bind() -> void:
	footer_message(&"auto_dev", "")
	for c in _pos_box.get_children():
		c.queue_free()
	var dev := _dev()
	if dev != null:
		for i in dev.positions():
			var b := Button.new()
			b.text = dev.pos_text(i)
			b.pressed.connect(_on_pos.bind(i))
			_pos_box.add_child(b)
	refresh()


func _dev() -> C_PowerDevice:
	return target.get_comp(C_PowerDevice) as C_PowerDevice if target else null


func refresh() -> void:
	var dev := _dev()
	if dev == null:
		return
	_state.text = "%s: %s" % [dev.title(), dev.state_text()]
	var fuse := dev as C_Fuse
	_fuse_box.visible = fuse != null
	if fuse != null:
		_syncing = true
		_limit.set_value_no_signal(fuse.limit_a)
		_syncing = false
		_replace.disabled = not fuse.blown
	var parts: PackedStringArray = []
	for id in PowerTasks.TASKS:
		var r := PowerTasks.evaluate(id, panel.get_tree())
		parts.append("%s %s\n%s" % ["✔" if r.done else "•", PowerTasks.TASKS[id], "\n".join(PackedStringArray(r.lines))])
	_tasks.text = "\n\n".join(parts)


func _on_pos(i: int) -> void:
	var dev := _dev()
	if dev:
		dev.set_pos(i)
		refresh()


func _on_limit_changed(v: float) -> void:
	if _syncing:
		return
	var f := _dev() as C_Fuse
	if f:
		f.set_limit(v)


func _on_replace() -> void:
	var f := _dev() as C_Fuse
	if f:
		f.replace_fuse()
		refresh()


func _on_autowire() -> void:
	var dev := _dev()
	if dev == null:
		return
	var n := dev.autowire(target.get_parent())
	if n > 0:
		footer_message(&"auto_dev", "Создано проводов: %d" % n, &"ok")
	else:
		footer_message(&"auto_dev", "Нечего подключать: нужен пульт с выводом, клипы с метками его вывода", &"warn")
	refresh()
