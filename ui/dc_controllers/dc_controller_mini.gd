extends DCController

########################
## Контроллер с минидизайном
########################
@onready var power_slider: VSlider = %PowerSlider


## Наследует контроллер_р но упрощает его функции за счет дефолтных нод управления

func _ready() -> void:
	_attach_source()
	# Открыта или спрятана: задает DCPanelHost из сейва или от прежней панели, как в базовом классе
	%ShowControllerButton.button_pressed = open_on_start
	_apply_visibility()
	_follow_tool_dock()   # базовый _ready не вызывается: положение над ToolDock подключаем сами
	
	# Это надо до тех пор, пока при старте сцены UI есть контроллер(для дебага в общем)
	#object_setting  =load("res://ui/dc_controllers/dc_controller_mini.tres")
	
	# подключаемся к powermanager
	#change_power_pwm.connect(PGM.on_change_power_dc)
	#onoff_power_pwm.connect(PGM.on_onoff_power_dc)

	## слайдер по состоянию источника (смена дизайна панели, загрузка)
	sync_from_source()



## Запись текущего питания в переменные и сигнал в powercontroller 
func current_power_local() -> void:
	var value = $PowerSlider.value
	power_local = int(value * power_mult)
	%PowerLabel.text = str(power_local) + '%'
	# Подача сигнала с питание в контур. -1 - во все выводы источника
	_send_power()



## Мини-дизайн: слайдер вместо ручки
func _apply_command_to_controls(p: int) -> void:
	power_slider.set_value_no_signal(p)



## Слайдер питания есть только в этом контроллере, поэтому обработка его сигнала
func _on_power_slider_value_changed(_value: float) -> void:
	current_power_local()



## Эти функции переписываем пустыми, потому функционал родкласса здесь не нужен
func _input(_event) -> void:
	pass
func _physics_process(_delta: float) -> void:
	pass

## Обнуляем слайдер по пкм
func _on_power_slider_gui_input(event: InputEvent) -> void:
	if (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT):
		%PowerSlider.value = 0
