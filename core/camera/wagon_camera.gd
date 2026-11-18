extends Node3D

@export var mouse_sensitivity: float = 0.05
@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var camera: Camera3D = $SpringArm3D/Camera3D

func activate() -> void:
	# Переключаем рендер на эту камеру
	camera.make_current()

func _unhandled_input(event: InputEvent) -> void:
	# Если эта камера не активна, игнорируем ввод
	if not camera.current:
		return

	# Вращение
	if event is InputEventMouseMotion and Input.is_action_pressed("mmb"):
		rotate_y(-event.relative.x * mouse_sensitivity)
		spring_arm.rotate_x(-event.relative.y * mouse_sensitivity)
		spring_arm.rotation.x = clamp(spring_arm.rotation.x, -PI/2.1, PI/6)

	# Зум
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			spring_arm.spring_length = clamp(spring_arm.spring_length - 1.0, 3.0, 25.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			spring_arm.spring_length = clamp(spring_arm.spring_length + 1.0, 3.0, 25.0)
