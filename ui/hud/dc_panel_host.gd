class_name DCPanelHost extends Control

###########################
## DCPanelHost: владелец 2D-контроллера питания (U15, решение 20.11.2026)
###########################
## 2D-контроллер ставится как обычный объект: карточкой в ToolDock Operate, пишется в сейв.
## В игре один контроллер или ни одного: выбор другого дизайна заменяет прежний, источник питания и его команды
## остаются (панель отпускает источник в _exit_tree, новая той же модели забирает его). Удаление только кнопкой в хедере
## ToolDock (Operate) через окно подтверждения. Новая партия без панели; сейв до этого шага получает панель mini.
## Лежит в HUD ниже SideDock (SideDock накрывает панель, ToolDock накрывает обоих), тема и скрытие HUD работают.
## Положение над нижним рядом панель считает сама (DCController._apply_visibility).

## Панель появилась или исчезла (кнопка «Удалить 2D-контроллер» включается и выключается)
signal panel_changed(has_panel: bool)

## Сейв без поля о контроллере (до U15) получает мини-панель, как было раньше
const LEGACY_SETTING := "res://ui/dc_controllers/objects/dc_2d_mini.tres"

var panel: DCController


## Группа нужна раньше _ready соседей: SaveManager находит хозяина по ней
func _enter_tree() -> void:
	add_to_group(&"dc_panel_host")


func has_panel() -> bool:
	return is_instance_valid(panel)


## Карточка 2D-контроллера из ToolDock: поставить или заменить. Тот же дизайн второй раз ничего не меняет
func place(setting: DCControllerSetting) -> void:
	if setting == null or setting.scene == null:
		return
	var open := true
	if has_panel():
		if panel.setting != null and panel.setting.resource_path == setting.resource_path:
			return
		open = panel.is_open()   # новая панель открыта или спрятана так же, как прежняя
		_drop_panel()
	_make_panel(setting, open)


## Убрать панель без вопросов (новая партия, загрузка). Источник питания остается на столе
func remove() -> void:
	if not has_panel():
		return
	_drop_panel()
	panel_changed.emit(false)


## Кнопка «Удалить 2D-контроллер»: сначала вопрос
func request_remove() -> void:
	if not has_panel():
		return
	var dialog := get_node_or_null("%ConfirmDialog") as ConfirmDialog
	if dialog == null or await dialog.ask("Удалить 2D-контроллер", "Убрать панель управления питанием? Источник питания останется на столе со своими командами.", "Удалить", "Отмена"):
		remove()


## Новая партия: панели нет
func clear() -> void:
	remove()


## Для SaveManager: путь ресурса настройки и «открыта»; пустой путь: контроллера нет
func save_state() -> Dictionary:
	if has_panel() and panel.setting != null:
		return {"setting_path": panel.setting.resource_path, "open": panel.is_open()}
	return {"setting_path": "", "open": true}


## Из SaveManager после загрузки сети питания. Пустой словарь: сейв до U15, панель mini
func load_state(state: Dictionary) -> void:
	if state.is_empty():
		state = {"setting_path": LEGACY_SETTING, "open": true}
	var path := String(state.get("setting_path", ""))
	if path == "":
		remove()
		return
	var setting := load(path) as DCControllerSetting
	if setting == null or setting.scene == null:
		push_warning("DCPanelHost: нет настройки контроллера %s, панель не создана" % path)
		remove()
		return
	if has_panel():
		_drop_panel()   # заново: новая панель забирает источник из загруженной сети и открывается как в сейве
	_make_panel(setting, bool(state.get("open", true)))


func _make_panel(setting: DCControllerSetting, open: bool) -> void:
	var p := setting.scene.instantiate() as DCController
	if p == null:
		push_warning("DCPanelHost: сцена %s не DCController" % setting.resource_path)
		return
	p.new_setting(setting)
	p.open_on_start = open
	# Якоря сверху слева: положение по высоте задает сама панель (над нижним рядом), как у прежней панели в сцене UI
	p.anchor_top = 0.0
	p.anchor_bottom = 0.0
	add_child(p)
	panel = p
	panel_changed.emit(true)


## Снять панель из дерева сразу, не отложенно: источник освобождается в _exit_tree, и новая панель его заберет
func _drop_panel() -> void:
	panel.hide()
	if panel.get_parent() == self:
		remove_child(panel)
	panel.queue_free()
	panel = null
