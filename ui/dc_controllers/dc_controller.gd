class_name DCController extends Panel

################################
## DC (Direct Current) Controller PWM
################################

## Базовый контроллер питания жд, все контроллеры дочерние от него
## DCC (Digital Command Control) будет потом
## 
## Ручка управляется родительской нодой HandlePower, 
## начальное положение и размер - Handle_texture
##
## Контроллер выдает питание в PowerControlleer, который занимается дальнейшей его обработкой
## Изначально предполагает pwm (ШИМ) структуру. То есть можно выбирать контур для регулировки мощностью. Однако простейшая реализация может быть только с общей регулировкой и наследуется из этого класса
## 
## Для каждого контроллера есть свой ресурс в папке object. Он используется при нажатии кнопки создания в меню лвл2


########################
##  Основные переменные
########################

## Ресурс с настройками экземпляра 
#var controller_setting :DCControllerSetting
var setting :DCControllerSetting

## Подача мощности в 0 - 100% с учетом направления +-. 
# текущий повер внутри контроллера
var power_local : int = 0 
#var power_memory : Dictionary[int, int] = {}

## Множитель мощности для умножения мощности. Не реализовано. Учитывать float!
var power_mult : float = 1.0

## Активный контур, в который передается питание. 0 - во все
var active_contour : int = -1

## Источник питания панели (PowerSource в PGM): команды, аварийный стоп и защита живут в нём, панель только ввод
var source: PowerSource
## Панель при создании открыта (true) или спрятана за левый край. Задает DCPanelHost до add_child (сейв, смена дизайна)
var open_on_start := true
## Идет синхронизация ручки с источником (загрузка, смена панели): команды в сеть не шлются
var _syncing := false
var _indicators: DCIndicators

## Mаксимальный угол поворота ручки, чем меньше, тем надежней блокровка на крайних значениях
@export var handle_max_angle : int = 330
## Вращение ручки в обе стороны вместо переключателя полярности
@export var rotation_with_direction : bool = false


########################
##  Внутренние переменные и флаги 
########################

##REF проверить переменные, которые можно передавать через аргументы, чтобы не болтались в памяти
var sign_power = 1 # полярность 
var mouse_on_handle = false #мышь над ручкой
var mousepos # позиция мыши
var delta_a = 0 #дельта между углом мыши и ручки
var power_changing = false #идет изменение повер
var power_min = false #ручка в мин позиции
var power_max = false #ручка в макс позиции
var pre_a = 0 #предыдущее значение угла для расчетов



# ⚡Сигнал текущей power в обработчик powermanager
#signal change_power_pwm(power, contour)
@warning_ignore("unused_signal")
signal onoff_power_pwm(onoff)



########################
##   Переопределенные функции
########################

func _ready() -> void:
	_attach_source()
	
	# Имя контроллера на корпусе
	var _model_index = 'B' if rotation_with_direction else 'A'
	$ModelLabel.text += str(handle_max_angle) + _model_index
	
	# Открыта или скрыта панель: задает DCPanelHost из сейва или от прежней панели (U15)
	%ShowControllerButton.button_pressed = open_on_start
	_apply_visibility()
	_follow_tool_dock()
	
	# по умолчанию слайдер полярности есть, иначе настраиваем положение ручки
	if rotation_with_direction :
		%HandlePower.rotation_degrees = float (handle_max_angle) / 2
		$DirectionSliderLabels.visible = false
		$DirectionSlider.visible = false
	else:
		%HandlePower.rotation_degrees = 0 
	$HandlePower/Handle_texture.rotation_degrees = - float(handle_max_angle) / 2

	# Ручка по состоянию источника (смена дизайна панели, загрузка): питание не теряется
	sync_from_source()



## Берем источник из PGM (свободный той же модели забираем, иначе создаем), строим индикаторы.
## Вызывается в начале _ready каждого дизайна
func _attach_source() -> void:
	var model: StringName = setting.model_id if setting != null else PowerModels.MULTI
	source = PGM.register_source(model, self)
	# Новая или загруженная партия: ручка встает по источнику (ATTN_10 P5, D2)
	PGM.state_reset.connect(reset_handle)
	PGM.state_loaded.connect(sync_from_source)
	_indicators = DCIndicators.create()
	add_child(_indicators)
	_indicators.setup(source, size.x)
	# Окошко индикаторов стоит над пультом (его высота растет вверх)
	_indicators.minimum_size_changed.connect(_place_indicators)
	_place_indicators()


func _place_indicators() -> void:
	if _indicators == null:
		return
	_indicators.size = _indicators.get_combined_minimum_size()
	_indicators.position = Vector2(0, -_indicators.size.y - 2)


func _exit_tree() -> void:
	# Панель закрыта: источник остается на столе со своими командами, следующая панель его заберет
	PGM.unregister_source(source)
	# Снятая панель живет до конца кадра: сброс и загрузка сети ее больше не трогают
	if PGM.state_reset.is_connected(reset_handle):
		PGM.state_reset.disconnect(reset_handle)
	if PGM.state_loaded.is_connected(sync_from_source):
		PGM.state_loaded.disconnect(sync_from_source)


## Открыта ли панель (кнопка у края экрана нажата)
func is_open() -> bool:
	return %ShowControllerButton.button_pressed


## Метка вывода по значению слайдера контура: -1 все, 0 никуда, дальше порядковый номер вывода источника
func _slider_to_label(v: int) -> int:
	if v <= 0 or source == null:
		return v
	return source.outputs[v - 1].label if v <= source.outputs.size() else v


func _label_to_slider(l: int) -> int:
	if l <= 0 or source == null:
		return l
	for i in source.outputs.size():
		if source.outputs[i].label == l:
			return i + 1
	return -1


## Команда, которую показывает ручка: у выбранного вывода, при «все» у первого с командой
func _shown_command() -> int:
	if source == null:
		return 0
	if source.selected > 0:
		var o := source.output_by_label(source.selected)
		if o != null:
			return o.command
	for o in source.outputs:
		if o.command != 0:
			return o.command
	return 0


## Ручка, слайдеры и кнопка по состоянию источника. Команды в сеть не шлются
func sync_from_source() -> void:
	if source == null:
		return
	_syncing = true
	power_changing = false
	if _indicators:
		_indicators.refresh()
	var slider_v := _label_to_slider(source.selected)
	if %ContourSlider.max_value >= slider_v:
		%ContourSlider.set_value_no_signal(slider_v)
	%PowerButton.set_pressed_no_signal(not source.estop)
	active_contour = 0 if source.estop else _slider_to_label(int(%ContourSlider.value))
	_apply_command_to_controls(_shown_command())
	current_power_local()
	_syncing = false


## Положение ручки (или слайдера) по команде в процентах со знаком
func _apply_command_to_controls(p: int) -> void:
	var angle: float
	if rotation_with_direction:
		angle = (float(p) / 2.0 + 50.0) / 100.0 * float(handle_max_angle)
	else:
		sign_power = -1 if p < 0 else 1
		$DirectionSlider.set_value_no_signal(sign_power)
		angle = absf(float(p)) / 100.0 * float(handle_max_angle)
	%HandlePower.rotation_degrees = angle


## Сброс сети (PGM.state_reset): команды в источниках уже 0, ручка догоняет
func reset_handle() -> void:
	sync_from_source()


## Единственная точка отправки команды в сеть. При синхронизации молчит
func _send_power() -> void:
	if _syncing or source == null:
		return
	PGM.set_command(active_contour, power_local, source)



## Контроль ручки
func _input(event) -> void:
	#освобождаем ручку
	if Input.is_action_just_released("lmb"):
		mousepos = get_viewport().get_mouse_position()
		power_changing = false

	# вращаем ручку
	if power_changing and event is InputEventMouseMotion:
		rotate_handle()



func _physics_process(_delta: float) -> void:
	# если ручку взяли, то смотрим позицию мыши
	if power_changing:
		mousepos = get_viewport().get_mouse_position()


########################
## Свои функции 
########################

## настройки передаются в объект перед реди
func new_setting(_setting: DCControllerSetting) -> void:
	setting = _setting 
	# Это нужно и для передачи туда текущего остояния питания
	rotation_with_direction = setting.rotation_with_direction
	handle_max_angle = setting.handle_max_angle
	name =  'DCControllerPanel'  # Имя не влияет ни на что пока



## Меняет текущее значение повер из положения ручки и позиции sign_power
## Вызывается при вращении ручки и смене полярности в слайдере
## Выдает сигнал для PowerController с контуром(только + ) питанием на нем
func current_power_local() -> void:
	var _handle_angle = %HandlePower.rotation_degrees
	#power_local  = int(power_mult * (round(_handle_angle / handle_max_angle*100) * sign_power))
	power_local  = int(power_mult * (_handle_angle / handle_max_angle * 100 * sign_power))
	# Пересчет если в обе стороны крутим
	if rotation_with_direction:
		power_local  =int(power_mult * (power_local - 50) * 2)
	var _dir
	if power_local > 0 :
		%DirectionLabel.text = '🠊'
		%PowerProgressBar.fill_mode = 0
	elif power_local < 0 :
		%DirectionLabel.text = '🠈'
		%PowerProgressBar.fill_mode = 1
	else:
		%DirectionLabel.text = '-'
	
	%PowerProgressBar.value = abs(power_local)
	%ContourLabel.text = 'C: ' + str(active_contour)

	# Подача сигнала с питание в контур. -1 - во все выводы источника
	_send_power()


## Обработка вращения ручки
func rotate_handle() -> void:
	# угол положения мыши относительно ручки в положении 0
	var mouse_a0 = floor( rad_to_deg(%HandlePower.global_position.angle_to_point(mousepos)))

	# угол положения мыши относительно ручки если ручка не в 0
	var mouse_a = mouse_a0 - delta_a
	
	# считаем угол в диапазоне 0-max_угол 
	var calibrating_a = calc_calibrating_angle(mouse_a)
	
	#фиксируем угол с учетом минмакс значений
	calibrating_a = check_minmax(calibrating_a, handle_max_angle) 
	%HandlePower.rotation_degrees = calibrating_a 
	
	# Выставляем значение power_local по углу ручки с учетом полярности и сигнал в повер контроллер
	current_power_local()




########################
## Служебные функции
########################

## Устанавливаем угол ручки с учетом диапазона и ограничителей
func check_minmax(calibrating_a, _max=270):
	if calibrating_a >= 0 and calibrating_a <= _max: # в диапазоне регулировки
		if power_min: #если завели в мин
			if calibrating_a < 20: # то пока не поставить в 20 и меньше ничего не будет
				power_min = false
			else:
				calibrating_a = 0
	
		elif power_max: #если завели в макс 
			if calibrating_a > _max - 20: # то пока не поставить в 250 и больше ничего не будет
				power_max = false
			else:
				calibrating_a = _max

	# если очень резко дергать, то проброс к минмакс в этом диапазоне
	elif pre_a <= 50:
		calibrating_a = 0
		power_min = true
		
	elif pre_a >= _max - 50:
		calibrating_a = _max
		power_max = true
		
	#если происходит перекидывание то обнуляем
	if calibrating_a > _max:
		printt('Error rortating handle! Set zero position.')
		calibrating_a = 0
		
	pre_a = calibrating_a
	return calibrating_a



## задаем угол в диапазоне 0-360
func calc_calibrating_angle(a)-> float:
	#устанавливаем а в 0-360
	if  a < 0:
		a += 360
	if a > 360:
		a -= floor(a / 360) * 360

	# Смещение на угол калибрате
	if a >= 360 :
		a -= 360 
	
	return a




########################
## Сигналы 
########################

## Переключатель слайдера направления 🠊🠈
func _on_direction_slider_value_changed(value: float) -> void:
	if rotation_with_direction:
		#направление подачи энергии - -1 +1
		match  int(value):
			1 : %DirectionLabel.text = '🠊'
			0 : %DirectionLabel.text = '-'
			-1 : %DirectionLabel.text = '🠈'
	sign_power = value
	current_power_local()



##Кнопка вкл\выкл видимости контроллера
func _on_show_controller_button_pressed() -> void:
	_apply_visibility()


## Положение над нижним рядом следует за его высотой и за размером окна. Зовут _ready базового класса
## и дизайнов со своим _ready (мини-дизайн базовый _ready не вызывает)
func _follow_tool_dock() -> void:
	get_viewport().size_changed.connect(_apply_visibility)
	var dock := get_tree().get_first_node_in_group(&"tool_dock_view") as ToolDockView
	if dock != null:
		dock.occupied_changed.connect(_apply_visibility)


## Положение панели: стоит над тем, что занимает нижний ряд у левого края (панель категорий или ToolDock),
## зазор 8 px; ряд спрятан: отступ от низа окна 12. Открытая или спрятанная за левый край.
## Окно индикаторов прячется вместе с панелью (иначе из-за края торчит его правый хвост)
func _apply_visibility() -> void:
	var contr_size = $".".size
	var y_offset := 12.0
	var dock := get_tree().get_first_node_in_group(&"tool_dock_view") as ToolDockView
	if dock != null and dock.occupied_height() > 0.0:
		y_offset = dock.occupied_height() + 8.0
	var open: bool = %ShowControllerButton.button_pressed
	if open:
		$".".position = Vector2(5, get_viewport().get_visible_rect().size.y - contr_size.y - y_offset)
		%ShowControllerButton.text = '<'
	else :
		$".".position = Vector2( -contr_size.x , get_viewport().get_visible_rect().size.y - contr_size.y - y_offset)
		%ShowControllerButton.text = '>'
	if _indicators != null:
		_indicators.visible = open



## мышь на ручке	
func _on_handle_texture_mouse_entered() -> void:
	mouse_on_handle = true



## мышь не на ручке
func _on_handle_texture_mouse_exited() -> void:
	mouse_on_handle = false



## События на ручке
func _on_handle_texture_gui_input(_event: InputEvent) -> void:
	#если мышь на ручке, нажата лкм повер не начали менять, то задаем старт
	if mouse_on_handle and Input.is_action_just_pressed("lmb") and !power_changing:
		mousepos = get_viewport().get_mouse_position()
		delta_a = floor(rad_to_deg(%HandlePower.global_position.angle_to_point(mousepos) - %HandlePower.rotation))
		power_changing = true
	
	# По пкм обнуляем ручку
	if mouse_on_handle and Input.is_action_just_pressed("rmb") and !power_changing:
		if rotation_with_direction :
			%HandlePower.rotation_degrees = float (handle_max_angle) / 2
		else:
			%HandlePower.rotation_degrees = 0 
		
		current_power_local()

## Слайдер для активного контура. -1 - питает все контуры
func _on_contour_slider_value_changed(value: float) -> void:
	active_contour = _slider_to_label(int(value))
	if source != null:
		source.selected = active_contour
	%ContourLabel.text = 'C: ' + str(active_contour)
	if _indicators:
		_indicators.refresh()



## Кнопка выключени питания. Импользует множитель power_mult = 0
func _on_power_button_pressed() -> void:
	var pwr_on = %PowerButton.button_pressed
	if !pwr_on: #Выкл
		#power_mult = 0
		active_contour = 0

	else: # Вкл
		#power_mult = 1
		active_contour = _slider_to_label(int(%ContourSlider.value))
		#onoff_power_pwm.emit(pwr_on) # восстановит все из мемори
		current_power_local() # обновляем питание по ручке
	
	# Аварийный стоп только этого источника; команды сохраняются, защиту не трогает (Q8)
	PGM.emergency_stop(!pwr_on, source)

	
