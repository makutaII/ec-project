class_name C_Engine extends ICapability

####################
## Способность, Библиотека действий. Она живет на объекте всегда.
####################
## (Мотор): Считывает напряжение через контакт с C_PowerTrack под собой и преобразует его в вектор силы (Torque) или целевую скорость.

## Максимальная сила тяги двигателя (Н), ограничение физики мотора
@export var max_tractive_force: float = 30.0

## Максимальная скорость (м/с), которую мотор может развить в вакууме при power=100.
## По сути, это коэффициент KV мотора (обороты на вольт), переведенный в линейную скорость.
@export var max_theoretical_speed: float = 6.0

## Порог страгивания, % напряжения (WagonConfig.start_voltage). Ниже порога сила 0, питание есть
@export var start_voltage: float = 6.0
## Ток холостого хода мотора, А (WagonConfig.motor_current_idle)
@export var motor_current_idle: float = 0.15
## Стопорный ток мотора, А, при полной силе: разгон, затор (WagonConfig.motor_current_stall)
@export var motor_current_stall: float = 1.2

## Порт потребителя в решателе нагрузки (PGM)
var _port := PowerPort.new()

# Что в моменте на моторе
var power = {
	'net_id': 0 ,
	'voltage': 0.0 ,
	}


func on_added() -> void:
	_port.kind = PowerPort.Kind.MOTOR
	_port.owner = self
	PGM.register_port(_port)


func on_removed() -> void:
	PGM.unregister_port(_port)


func _physics_process(_delta: float) -> void:
	
	var chassis = entity.get_comp(C_Chassis) as C_Chassis
	if not chassis or not chassis.is_on_rails:
		_port.net = 0
		_port.load_current = 0.0
		#XX clade
		entity.send_event('on_force_changed', {'force': 0.0, 'powered': false})
		return
	
	var bogie_comp = entity.get_comp(C_Bogie) as C_Bogie
	# Одно решение о питании на все тележки (C_Bogie.best_supply): без дерганья на изостыках
	var supply: Dictionary = bogie_comp.best_supply()
	var active_voltage: float = supply.voltage
	var current_contour: int = supply.net

	# Обновляем состояние мотора
	power.net_id = current_contour
	power.voltage = active_voltage
	_port.net = current_contour
	_port.voltage = active_voltage

	# Если 0, то выход
	if active_voltage == 0.0:
		_port.load_current = 0.0
		#XX claude
		entity.send_event('on_force_changed', {'force': 0.0, 'powered': false})
		return

	# Ниже порога страгивания мотор не тянет: питание есть (powered), силы нет
	if absf(active_voltage) < start_voltage:
		_port.load_current = motor_current_idle
		entity.send_event('on_force_changed', {'force': 0.0, 'powered': true})
		return

# 1. Рассчитываем целевую скорость V_target для текущего напряжения (с учётом полярности)
	var voltage_ratio = active_voltage / 100.0 # Диапазон от -1.0 до +1.0
	var target_speed = max_theoretical_speed * voltage_ratio

	# 2. Скорость вала мотора: при сцеплении она равна скорости шасси, в пробуксовке это скорость колёс
	var current_speed = chassis.get_motor_speed()

	# 3. ЭЛЕКТРОДИНАМИЧЕСКОЕ ТОРМОЖЕНИЕ И ТЯГА (ПротивоЭДС)
	# Сила пропорциональна разнице скоростей: (V_target - V_current) / V_max
	var speed_delta_ratio = 0.0
	if max_theoretical_speed > 0.0:
		speed_delta_ratio = (target_speed - current_speed) / max_theoretical_speed

	# Ограничиваем пропорцию диапазоном [-1.0, 1.0] (пределы мощности мотора)
	speed_delta_ratio = clamp(speed_delta_ratio, -1.0, 1.0)

	# Итоговая сила мотора: 
	# Положительная  => тяга вперёд
	# Отрицательная  => АКТИВНОЕ торможение мотором (генераторный режим / червяк)
	var engine_force = max_tractive_force * speed_delta_ratio
	# Ток мотора по доле силы (D3): затор или разгон дают ток до стопорного. Читает PowerSolver
	_port.load_current = PowerPort.motor_current(motor_current_idle, motor_current_stall, absf(speed_delta_ratio))

	# Отправляем рассчитанную силу в C_Chassis
	#XX claude
	# target_speed и motor_k (Н на м/с) нужны шасси, чтобы раскручивать колёса в пробуксовке
	var motor_k := max_tractive_force / max_theoretical_speed if max_theoretical_speed > 0.0 else 0.0
	entity.send_event('on_force_changed', {'force': engine_force, 'powered': true, 'active': true,
			'target_speed': target_speed, 'motor_k': motor_k})


## Строки подсказки при наведении и вкладки «Подсказки» (контракт HoverLines, U5a.5)
func get_hover_lines() -> Array:
	return [HoverLines.line("Контур: %s, напряжение: %s" % [power.net_id, power.voltage])]
