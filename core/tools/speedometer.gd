class_name Speedometer extends Node3D

########################
## Класс замеров скоростей
########################
## 
## Замеряет скорость тела между 2мя блоками
## Замеряет текущую скорость тела

## Дистанция замера
@export var distance_m := 20.0 



@onready var controller: ToolController = %ToolController

# Вагон, на котором меряется скорость постоянно
@onready var current_entity : Entity

## Служебные переменные
var current_time:float # Время начала замера 
var finish_time:float	# Время конца замера
var elapsed_time_sec :float # Время измерения
var rec = false	# Флаг начала замера

## Это настройки тиков для вывода
@export var T: int = 1 # Срабатывание каждые 10 физических тиков (например, каждые 30/60сек)
var tick_counter: int = 0

## Если меня клинит, то 
## 1м		=	100см
## 1м		=	1000мм
## 0.1м		=	10см
##
## НO			GODOT
## 1см 		=	1м
## 10мм		=	1м
## 1м		=	100м
## 0.01м	=	1м  отсюда SCALE_GEOMETRY = 100

## Средняя скорость. Реальное физическое значение 3,13 м/с (~11,3 км/ч)

## Масштабы пересчета
const SCALE_GEOMETRY := 100.0        # 1:100 из НО в GODOT
const HO_SCALE := 87.0               # реальный масштаб из HO в реальные метры


func _ready() -> void:

	#Блок финиш на расстояние замера
	$Finish.position.z = $Start.position.z - distance_m 
	# InfoPanel находим по группе: игровой код не держит ссылок на узлы UI
	var _info := get_tree().get_first_node_in_group(&"info_panel")
	if _info:
		_info.s_select_entity.connect(on_select_wagon)
	
	

func on_select_wagon(_selected:Variant, _speedometer_on: bool, _on_vert := false):
	
	current_entity = _selected
	
	if !_speedometer_on:
		%MainSpeedPanel.hide()
		self.hide()
		return
		
	if not _selected:
		current_entity = null
		#wagon = null
		%WagonNameLabel.text = '-'
		self.hide()
		return
	
	var _comp = current_entity.get_comp(C_Chassis)
	if _comp:
		#wagon = _comp.rb
		%WagonNameLabel.text = name + ' ' +  _selected.name
		self.show()
		%MainSpeedPanel.show()
		
	if _on_vert:
		self.rotation_degrees.x = 90
	else:
		self.rotation_degrees.x = 0
		



func _physics_process(_delta: float) -> void:
	tick_counter += 1
	if tick_counter % T == 0:# операция деления по модулю (остаток от деления)
		tick_counter = 0
		show_speed() # Меряем и выводим скорость по 30 тиков
	


## Вывод скорости на спидпанель
func show_speed():
	if current_entity != null:
		var speed = get_speed_data()
		if not speed: return
		%Godotmps.text = "%.1f" % speed.godot_mps
		%Godotkmh.text = "%.1f" % speed.godot_kmh
		%HOmps.text = "%.2f" % speed.ho_mps
		%HOkmh.text = "%.2f" % speed.ho_kmh
		%Realmps.text = "%.1f" % speed.real_mps
		%Realkmh.text = "%.1f" % speed.real_kmh
		%RecLabel.text = ' !Замер! ' if rec else str(elapsed_time_sec)




## Вычисляем скорость вагона
func get_speed_data() -> Dictionary:
	# скорость godot 
	var _comp = current_entity.get_comp(C_Chassis) as C_Chassis
	if not _comp: 
		return {}
	var godot_mps_v
	if _comp.is_on_rails:
		godot_mps_v = _comp.current_velocity_3d
	else:
		godot_mps_v =  _comp.rb.linear_velocity
	godot_mps_v.y = 0 
	var godot_mps = godot_mps_v.length()
	# Скорость игрушки
	var ho_mps = godot_mps / SCALE_GEOMETRY # SCALE_GEOMETRY = 100.0   
	# Скорость реального локо
	var v_real = ho_mps * HO_SCALE # HO_SCALE = 87.0   
	
	return {
		"godot_mps": godot_mps,			# +
		"godot_kmh": godot_mps * 3.6, 	# +
		"ho_mps": ho_mps,				# +
		"ho_kmh": ho_mps * 3.6,			# + 
		"real_mps": v_real,				# +
		"real_kmh": v_real * 3.6		# +
	}
	


##----Сигналы---

## Обработка сигнала с блоков старт\финиш
func _on_start_finish_body_entered(body: Node3D):
	if not current_entity: return
	var _comp  = current_entity.get_comp(C_Chassis)
	
	var wagon 
	if _comp:
		wagon = current_entity.get_comp(C_Chassis).rb
	if not wagon:
		wagon = body
		
	%SpeedometerContainer.visible = true
	%DistanceLabel.text = str(distance_m) + 'm'
	%SpeedGodotMps.text = "0"
	%SpeedGodotKmh.text = "0"
	%SpeedHoKmh.text = "0"
	%SpeedRealKmh.text = "0"
	#%RecLabel.text = str(elapsed_time_sec)
	if rec: # приехали к концу замера
		finish_time = Time.get_ticks_msec() # Текущее время
	else: # приехали началу замера
		current_time = Time.get_ticks_msec() # Текущее время
	
	elapsed_time_sec = abs(current_time - finish_time) /1000 
	
	
	#данные скорости из спидометра.
	if rec: 
		var _godot_mps : float = distance_m  / elapsed_time_sec
		var _godot_kmh :float = _godot_mps * 3.6
		
		var _ho_mps = _godot_mps / 100 #скорость игрушки  м\с
		var _ho_kmh = _ho_mps * 3.60  #скорость игрушки kм\ч 
		
		# Скалированная скорость прототипа
		var _real_mps = _ho_mps * 87
		var _real_kmh = _ho_kmh * 87
		
		%SpeedGodotMps.text = "%.2f" % _godot_mps
		%SpeedGodotKmh.text = "%.2f" % _godot_kmh
		%SpeedHoMps.text = "%.2f" % _ho_mps
		%SpeedHoKmh.text = "%.2f" % _ho_kmh
		%SpeedRealMps.text = "%.2f" % _real_mps
		%SpeedRealKmh.text = "%.2f" % _real_kmh
	rec= !rec



## закрываем окно замера по дистанции
func _on_button_pressed() -> void:
	%MainSpeedPanel.visible = !%MainSpeedPanel.visible 
