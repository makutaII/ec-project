class_name BuildOptions extends Resource

# U12 (ATTN_17 §17.13): новый файл
## Общие опции строительства: шаг поворота, привязка к сокетам и к сетке, лимиты flex.
## Живёт в Global.build_options. Читают BuildTool, DragTool, компоненты траков и SideDock;
## меняют SideDock и клавиша L. Значения пишутся в settings.cfg ([build]) при изменении.
## Загрузка сохранённых значений: load_saved() (из SideDock при старте UI, Settings к этому времени готов).

## ⚡ Значение изменилось (из панели, клавишей или загрузкой)
signal changed(key: StringName)

const SECTION := "build"
## Допустимые шаги поворота, градусы
const ROT_STEPS: Array[float] = [15.0, 45.0, 90.0]

## Шаг поворота Q/E, градусы (Shift+Q/E даёт мелкий шаг, он не настраивается)
var rot_step_deg := 45.0:
	set(v):
		if is_equal_approx(rot_step_deg, v):
			return
		rot_step_deg = v
		_commit(&"rot_step_deg", v)

## Притягивание траков и концов flex к свободным сокетам (снап и вертикальный магнит)
var socket_snap := true:
	set(v):
		if socket_snap == v:
			return
		socket_snap = v
		_commit(&"socket_snap", v)

## Привязка к сетке. Поле есть, логики пока нет (в панели серая строка)
var grid_snap := false:
	set(v):
		if grid_snap == v:
			return
		grid_snap = v
		_commit(&"grid_snap", v)

## Шаг сетки, единицы мира. Пока не используется
var grid_step := 1.0:
	set(v):
		if is_equal_approx(grid_step, v):
			return
		grid_step = v
		_commit(&"grid_step", v)

## Контроль лимитов flex (R, L, уклон, «под землёй»). Переключается клавишей L в BuildTool
var flex_limits := false:
	set(v):
		if flex_limits == v:
			return
		flex_limits = v
		_commit(&"flex_limits", v)

var _persist := false


func _commit(key: StringName, value: Variant) -> void:
	if _persist:
		Settings.set_value(SECTION, String(key), value)
	changed.emit(key)


## Читает сохранённые значения и дальше пишет изменения. Вызывать один раз после старта Settings
func load_saved() -> void:
	_persist = false
	for key in [&"rot_step_deg", &"socket_snap", &"grid_snap", &"grid_step", &"flex_limits"]:
		if Settings.has_value(SECTION, String(key)):
			var v: Variant = Settings.get_value(SECTION, String(key))
			if v != null and typeof(v) == typeof(get(key)):
				set(key, v)
	if not ROT_STEPS.has(rot_step_deg):
		rot_step_deg = 45.0
	_persist = true
