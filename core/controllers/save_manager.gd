extends Node
class_name SaveManager  #это в автолоад прописано
###########################
##💡 SaveManager - Системный сервис(autoload), контроль загрузки сохранения
############################
#TODO Занести в автолоад

# В экспортированной игре res:// только для чтения, сейвы пишем в user://
const SAVE_DIR = "user://saves/"
## Название макета по умолчанию
const DEFAULT_LAYOUT_NAME := "Новый макет"
# Старое место сейвов (разовый перенос) и эталонная диорама (шаблон только для чтения, грузится по F9 в debug)
const LEGACY_SAVE_DIR = "res://saves/"
const REFERENCE_DIR = "res://data/debug/"
## Сколько физкадров ждем, пока трак под вагоном станет доступен лучу (flex и коллизии строятся не с первого кадра)
const SNAP_RETRY_FRAMES := 60
## Сколько физкадров пробуем восстановить сцепки после посадки вагонов
const LINK_RETRY_FRAMES := 20

## Комната, выбранная при запуске (--room=<id>, источник start). Действует один раз: на первую загрузку или новую игру,
## дальше комнату задаёт сейв. Автосейв потом запишет эту комнату (ATTN_25 §25.3)
var _room_override: StringName = Global.start_room

## ⚡ Название макета сменилось (TopBar показывает его)
signal layout_name_changed(layout_name: String)
## Название текущего макета. Пишется в сейв, при New сбрасывается
var layout_name: String = DEFAULT_LAYOUT_NAME

# Ссылка на узел дерева, где лежат все рельсы
@onready var world_entities_root = "/root/GameRoot/EntitiesRoot"
@onready var entity_factory: EntityFactory = $"/root/GameRoot/EntityFactory"
@onready var tool_controller: ToolController = get_node_or_null("/root/GameRoot/ToolController")


func _ready() -> void:
	#await  get_tree().process_frame
	# Откладывает вызов функции до тех пор, пока дерево полностью не построится
	#load_game.call_deferred('autosave')
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	_migrate_legacy_saves()
	if FileAccess.file_exists(SAVE_DIR + "autosave.tres"):
		load_game('autosave')
	else:
		# Новая игра: автосейва ещё нет, создаём его из стартового состояния (комната по умолчанию или --room, стартовая секция стола)
		_apply_room_override()
		LYM.ensure_start_section(get_node_or_null(world_entities_root))   # XX claude-table T1
		save_game('autosave')


## Ставит комнату из --room=<id> (источник start), если она задана. true: комната применена. Аргумент расходуется в любом случае
func _apply_room_override() -> bool:
	var id := _room_override
	_room_override = &""
	if id == &"":
		return false
	var rb := _room()
	return rb != null and rb.request_room(id, RoomBuilder.SRC_START)


## Разово копирует сейвы из res://saves/ в user://saves/ (только то, чего там еще нет)
func _migrate_legacy_saves() -> void:
	if not DirAccess.dir_exists_absolute(LEGACY_SAVE_DIR):
		return
	for f in DirAccess.get_files_at(LEGACY_SAVE_DIR):
		if not f.ends_with('.tres') or FileAccess.file_exists(SAVE_DIR + f):
			continue
		DirAccess.copy_absolute(LEGACY_SAVE_DIR + f, SAVE_DIR + f)

#func _exit_tree() -> void:
	##await  get_tree().process_frame
	#save_game('autosave')
	

func _unhandled_input(_event: InputEvent) -> void:
	if Actions.pressed(_event, &"quick_save"):
		save_game('autosave')
	# F9 (debug): загрузить эталонную диораму
	if Global.debug_mode and Actions.pressed(_event, &"debug_load_reference"):
		load_game('reference', REFERENCE_DIR)


	
## Завершение работы
func _notification(what):
	### Срабатывает при закрытии окна (крестик, Alt+F4)
	if what == NOTIFICATION_WM_CLOSE_REQUEST: 
		#print('1')
		save_game('autosave')
		await  get_tree().process_frame
		
		get_tree().quit() # Разрешаем выход после сохранения
		##
	## Непонятно зачем, но Срабатывает при штатном выходе через get_tree().quit()
	#if what == NOTIFICATION_PREDELETE:
		#print('2')
		#save_game()
		
		###pass
	#pass



## Комната мира. null в режиме быстрой загрузки (fast_debug): комнаты нет
func _room() -> RoomBuilder:
	return get_node_or_null("/root/GameRoot/RoomBuilder") as RoomBuilder


#-------SAVE----------

## Возвращает true, если файл записан
func save_game(slot_name: String ='savegame') -> bool:

	## 💡 Данные для сохранения НЕ СУЩНОСТЕЙ
	
	#🚩сюда будем собирать все данные для сохранения
	#SavedGame - ресурс содержит все данные ИГРЫ
	var _saved_game : SavedGame = SavedGame.new()
	
	# 1️⃣ сохраняем камеру через ее метод
	_saved_game.gimbal = $"/root/GameRoot/Gimbal".save_global_state()
	#var save_data = {
		##"game_version": "1.0",
		##"global_managers": {
			##"gimbal" : _gimbal.save_global_state(),
			###"PowerGrid": PGM.save_global_state()
		##},
		#"entities": []
	#}


	# Комната мира: при старте автосейв поднимает ту же комнату
	var _rb := _room()
	if _rb and _rb.is_in_group(&"room_root"):
		_saved_game.room_id = _rb.get_room_id()
		_saved_game.room_controls = _rb.get_control_state()

	# XX claude-table T0: подмакетник (ATTN_23)
	_saved_game.layout = LYM.get_state()

	# Активный стиль траков макета (ATTN_17 §17.13)
	_saved_game.track_style = TSM.current_id

	# Название макета (U10)
	_saved_game.layout_name = layout_name

	# Источники питания и сеть: команды пультов, estop, защита (ATTN_10 D2)
	_saved_game.power_state = PGM.save_state()

	# Краска кистей (ATTN_13 §13.13)
	_saved_game.paint = TGM.paint.save_data()

	# 2️⃣ Собираем все сущности на столе
	var root_node = get_node_or_null(world_entities_root)
	if root_node:
		# проход по всем ентити 
		for _entity in root_node.get_children():
			if _entity is Entity:
				var e_data = _entity.save_entity() # Ентити Выдает свои данные 
				if not e_data.is_empty():
					_saved_game.entities.append(e_data) # записали

	await  get_tree().process_frame
	
	# Запись
	var _save_path = SAVE_DIR + slot_name + ".tres"	
	var _err := ResourceSaver.save(_saved_game, _save_path)
	if _err != OK:
		push_error("Не удалось сохранить игру: %s (код %d)" % [_save_path, _err])
		return false
	print("Игра успешно сохранена в: ", _save_path)
	return true



# Очистка от ентити. Хотя это больше подходит для тулза стройки, но пока тут
func clear_scene() -> void:
	var root_node = get_node(world_entities_root)

	# 1. ПОЛНАЯ ОЧИСТКА МАКЕТА
	for child in root_node.get_children():
		var clip = child.get_comp(C_PowerClip)
		if clip in PGM.active_clips:
			PGM.active_clips.erase(clip)
		child.queue_free()
	# Сеть питания: напряжения в ноль, защита снята, пульты ставят ручки в ноль (ATTN_10 P5)
	PGM.reset_state()
	# XX claude-table T1: очищен и стол: новый макет со стартовой секцией (убрать все секции игрок может и сам, T4b)
	LYM.reset()
	LYM.ensure_start_section(root_node)
	TGM.paint.clear()   # XX claude-terra 13.13 K1
	set_layout_name("")   # U10: новый макет
		
	#INFO ДЕРГАЕМ ПАНЕЛЬ!
	if tool_controller:
		tool_controller.publish_selection(null) # Очищаем панель на всякий случай


#-------СТИЛЬ ВСЕХ ТРАКОВ----------
var _style_apply_busy := false


## Этап 3 (ATTN_17 §17.13): пересобрать ВСЕ траки на столе в активном стиле сессии (TSM.current_id).
## Макет пишется в автосейв и тут же загружается с подменой style_id: сокеты, питание, стрелки, flex,
## опоры и вагоны восстанавливает обычная загрузка. До следующего сохранения автосейв хранит макет
## до смены стиля (откат: load_game('autosave') делать нельзя после повторного сохранения).
## Возвращает true, если макет пересобран
func apply_session_style_to_all() -> bool:
	if _style_apply_busy:
		return false
	_style_apply_busy = true
	if tool_controller:
		tool_controller.switch_tool(tool_controller.select_tool)   # призрак и перетаскивание не переживут очистку
		tool_controller.publish_selection(null)
	var saved: bool = await save_game('autosave')
	if not saved:
		push_error("Смена стиля отменена: автосейв не записан")
		_style_apply_busy = false
		return false
	await load_game('autosave', SAVE_DIR, TSM.current_id)
	_style_apply_busy = false
	return true


#-------LOAD----------
## style_override: подменить style_id у траков, у которых он записан в сейве (стиль «следовать сессии»).
## Пусто = стили из сейва как есть. Нужен для apply_session_style_to_all
func load_game(slot_name: String  ='savegame', dir: String = SAVE_DIR, style_override: StringName = &"") -> void:
	var save_path = dir + slot_name + ".tres"
	if not FileAccess.file_exists(save_path):
		return

	#🚩res все данные игры собраны здесь
	var _saved_game :SavedGame = load(save_path) as SavedGame #автокомплит
	if not _saved_game: return
	set_layout_name(_saved_game.layout_name)   # U10: пусто (старый сейв) = название по умолчанию
	# 0️⃣ комната мира (в памяти одна): до камеры, чтобы границы камеры были уже новой комнаты
	var _rb := _room()
	if _rb:
		# --room при запуске важнее комнаты сейва (один раз), иначе сейв просит свою комнату как «load»
		if not _apply_room_override():
			_rb.request_room(_saved_game.room_id, RoomBuilder.SRC_LOAD)
		# SavedGame.room_variants (варианты процедурной комнаты) читается, но игнорируется: процедурной комнаты больше нет (RM9b)
		# Свет и механизмы комнаты (RM6). Если вместо комнаты сейва взята другая (--room), её управления не трогаем
		_rb.set_control_state(_saved_game.room_controls if _rb.get_room_id() == _saved_game.room_id else {})
	# XX claude-table T0: подмакетник; пустой layout = стол как в v1
	LYM.set_state(_saved_game.layout)
	# 1️⃣ загружаем камеру вызывая ее метод
	$"/root/GameRoot/Gimbal".load_global_state(_saved_game.gimbal)
	var root_node = get_node(world_entities_root)
	# Активный стиль траков макета; в старом сейве его нет, тогда стиль по умолчанию
	TSM.set_current_from_save(_saved_game.track_style)
	
	# 1. ПОЛНАЯ ОЧИСТКА СТАРОГО МАКЕТА
	for child in root_node.get_children():
		child.queue_free()

	# Ждем, пока Godot гарантированно удалит старые объекты из памяти и физики
	await get_tree().physics_frame
	# Сеть питания и пульты: старые напряжения не переживают загрузку (ATTN_10 P5)
	PGM.reset_state()

	## 0️⃣ 3. СПАВН СУЩНОСТЕЙ С НАКАТЫВАНИЕМ ДАННЫХ
	var _skipped := {}   # setting_path -> сколько объектов пропущено (файла сеттинга нет)
	for e_data in _saved_game.entities:
		var _setting = load(e_data["setting_path"]) as EntitySetting
		if not _setting:
			_skipped[e_data["setting_path"]] = _skipped.get(e_data["setting_path"], 0) + 1
			continue
		
		## 1️⃣ Базовая сборка сущности: создание инстанса, добавление C_Identity, C_TrackVisual итд
		# style_id трака из сейва; записи без ключа (старые сейвы) читаются стилем по умолчанию
		var _style_id := StringName(e_data.get("style_id", TSM.default_id))
		if style_override != &"" and e_data.has("style_id"):
			_style_id = style_override   # трак без style_id (зафиксирован в объекте, не трак) не трогаем
		# XX claude-library L4: исполнение модели из сейва (ключа нет у обычных объектов и в старых сейвах)
		var _variant: Dictionary = e_data.get("variant", {})
		var new_entity = entity_factory.create_from_setting(_setting, _style_id, _variant)
		# Имя ноды (G239_01) Entity назначает сам в _ready из ключа объекта
		# Восстанавливаем трансформацию ДО добавления в дерево
		new_entity.global_transform = e_data["transform"]
		# Добавляем в мир
		root_node.add_child(new_entity)
		
		## 2️⃣   Накатываем сохраненные данные на компоненты
		# Список сохраненных компонентов
		var comp_data_map = e_data["components"]
		
		## Ищем компонент внутри созданной сущности по типу скрипта
		for comp_type in comp_data_map.keys(): # Тут нас интересуют только ключи
			# 🅰️ Если сохр комп найден в ентити, то накатываем сейв данные в него
			var current_comp = new_entity.get_comp(comp_type)
			if current_comp and current_comp.has_method("load_data"):
				current_comp.load_data(comp_data_map[comp_type]) # а сюда пойдут все данные компонента из сейва
				
			# 🅱️ Если не найден, то создаем и тогда грузим
			else: 
				var new_comp = comp_type.new()
				if new_comp.has_method("load_data"):
					new_comp.load_data(comp_data_map[comp_type])
					new_entity.add_component(new_comp) 

		# Вагон до посадки на рельсы стоит замороженным: без этого гравитация и скольжение по пандусу или эстакаде
		# сдвигают его, пока трак под ним достраивается (трение у вагона 0, рельс держит только расчет)
		var _kin := new_entity.get_comp(C_Kinematics) as C_Kinematics
		if _kin and is_instance_valid(_kin.rb):
			_kin.rb.freeze = true

	if not _skipped.is_empty():
		var _n := 0
		for _p in _skipped:
			_n += _skipped[_p]
		push_warning("SaveManager: пропущено объектов без сеттинга: %d (%s)" % [_n, ", ".join(_skipped.keys())])

	# XX claude-table T1: сейв до подмакетника (layout пуст): стартовая секция 200 x 100, как стол v1.
	# Сейв нового формата с пустым столом (T4b: убрали все секции) остаётся с пустым столом
	if _saved_game.layout.is_empty():
		LYM.ensure_start_section(root_node)

	# Источники питания: команды и защита из сейва, пульты ставят ручки (старый сейв: словарь пуст, остаются нули)
	PGM.load_state(_saved_game.power_state)

	# Краска кистей: после листов, чтобы оболочка уже была запрошена; пустой словарь очищает старую краску
	TGM.paint.load_data(_saved_game.paint)
	TGM.plaster_dirty()   # K3: крашеные ячейки на плоском верху входят в оболочку

	# 4. ВАЖНЕЙШИЙ ТАКТ СИНХРОНИЗАЦИИ ФИЗИКИ (см. Критические нюансы ниже)
	await get_tree().physics_frame

	if root_node:
		# 5. Вагоны садятся на рельсы (один раз: on_train_snapped асинхронный, повторный вызов только дублирует его).
		# Flex-трак и коллизии могут быть готовы не с первого кадра: кто не нашел трак под тележкой, пробует снова
		var wagons: Array[C_Chassis] = []
		for _entity in root_node.get_children():
			if _entity is Entity:
				var _comp := _entity.get_comp(C_Chassis) as C_Chassis
				if _comp:
					wagons.append(_comp)
		var pending := wagons.duplicate()
		var attempt := 0
		while not pending.is_empty():
			var still: Array = []
			for _w in pending:
				if is_instance_valid(_w) and not _w.restore_snap_after_load():
					still.append(_w)
			pending = still
			attempt += 1
			if pending.is_empty() or attempt > SNAP_RETRY_FRAMES:
				break
			await get_tree().physics_frame
		if not pending.is_empty():
			var _names: PackedStringArray = []
			for _w in pending:
				if is_instance_valid(_w):
					_names.append(str(_w.entity.name))
			push_warning("SaveManager: вагоны не нашли трак под тележкой после %d кадров: %s" % [attempt, ", ".join(_names)])

		# Кто не на рельсах (сошедший в сейве или трак не найден), возвращаем физике; севшие вагоны заморозит on_train_snapped
		for _w in wagons:
			if is_instance_valid(_w) and not _w.is_on_rails:
				var _k := _w.entity.get_comp(C_Kinematics) as C_Kinematics
				if _k and is_instance_valid(_k.rb):
					_k.rb.freeze = false

		# 5б. Сцепки восстанавливаем вторым проходом: нужны финальные позиции ВСЕХ вагонов. После посадки шасси
		# выставляет transform в первом физкадре, поэтому ждем кадр и повторяем, пока все сцепки не найдут пару
		var couplers: Array[C_Coupler] = []
		for _entity in root_node.get_children():
			if _entity is Entity:
				var _cp := _entity.get_comp(C_Coupler) as C_Coupler
				if _cp:
					couplers.append(_cp)
		for _try in LINK_RETRY_FRAMES:
			await get_tree().physics_frame
			var open_links := 0
			for _cp in couplers:
				if is_instance_valid(_cp):
					_cp.restore_links_after_load()
					if _cp.has_unrestored_links():
						open_links += 1
			if open_links == 0:
				break
	

	#DEBUG повер слой принудительно обновляем
	#PGM.toggle_power_layer(true)
	PGM.request_recalculate()
	print("Макет успешно загружен!")


#
#func menu_click_handling(_idx : int) -> void:
	#match _idx:
		#0: # save
			#save_game()
		#1: # load
			#load_game('savegame')
			##print(OS.get_data_dir())
			#pass
		#2: # ++
			#pass
		#3: #ничего
			#clear_scene()
			#pass
			#
		#5: #DEFAULT jolt
			##GM. apply_jolt_profile(GM.AssistProfile.DEFAULT) 
			#pass
		#6: #STABLE jolt
			##GM. apply_jolt_profile(GM.AssistProfile.STABLE) 
			#pass
		#7: #EXTREME jolt
			##GM. apply_jolt_profile(GM.AssistProfile.EXTREME) 
			#pass
	#pass
	#


## U10: ставит название макета (пусто: по умолчанию) и сообщает TopBar
func set_layout_name(new_name: String) -> void:
	var n := new_name.strip_edges()
	layout_name = n if n != "" else DEFAULT_LAYOUT_NAME
	layout_name_changed.emit(layout_name)


## U10: имя файла сейва из названия макета: без символов, недопустимых в имени файла
static func slot_from_name(layout: String) -> String:
	var s := layout.strip_edges()
	for ch in ["\\", "/", ":", "*", "?", "\"", "<", ">", "|", "."]:
		s = s.replace(ch, "_")
	return s if s != "" else "savegame"


## U10: файлы из user://saves/, свежие первыми: [{slot, path, time (unix, UTC)}]
func list_saves() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.get_extension() != "tres":
			continue
		out.append({"slot": f.get_basename(), "path": SAVE_DIR + f, "time": FileAccess.get_modified_time(SAVE_DIR + f)})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["time"] > b["time"])
	return out


## U10: выход из игры из меню: автосейв и закрытие (то же, что при закрытии окна)
func quit_game() -> void:
	await save_game('autosave')
	get_tree().quit()
