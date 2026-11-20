@tool
class_name KickCharge extends RefCounted

###########################
## Пинок рукой с зарядкой: сила от времени удержания (ATTN_27)
###########################
## Общая часть для пинка клавишами PgUp и PgDn (SelectTool, любой вагон) и мышью (C_RideCar, вагоны горок).
## Нажатие короче hold_min это обычный пинок силой short_power (как до зарядки). Дольше: сила растёт
## от power_min до power_max за charge_time секунд удержания сверх hold_min. Отпускание пинает.
## Сила в тех же единицах, что у события on_train_kicked (power_kick): Δv вагона массой 2 равно силе.
## Вагон может переопределить числа: SelectTool шлёт ему событие on_kick_params со словарём (C_RideCar берёт их из RideProfile).
## Подсказку с силой показывает вызывающий через InfoTips (текст даёт label_text).

const HOLD_MIN := 0.25
const CHARGE_TIME := 1.2
const POWER_MIN := 3.0
const POWER_MAX := 20.0
const SHORT_POWER := 10.0


## Параметры по умолчанию. Словарь изменяемый: компоненты вагона правят его в on_kick_params
static func defaults() -> Dictionary:
	return {
		"hold_min": HOLD_MIN,
		"charge_time": CHARGE_TIME,
		"power_min": POWER_MIN,
		"power_max": POWER_MAX,
		"short_power": SHORT_POWER,
	}


## Сила пинка при удержании t секунд (без знака: направление выбирает вызывающий)
static func power_at(t: float, p: Dictionary) -> float:
	var hold: float = p.hold_min
	if t < hold:
		return float(p.short_power)
	var k := clampf((t - hold) / maxf(float(p.charge_time), 0.05), 0.0, 1.0)
	return lerpf(float(p.power_min), float(p.power_max), k)


## Текст подсказки при зарядке
static func label_text(forward: bool, power: float) -> String:
	return "%s %.0f" % ["Пинок вперёд" if forward else "Пинок назад", power]
