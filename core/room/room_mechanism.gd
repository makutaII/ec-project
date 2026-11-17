class_name RoomMechanism extends RefCounted

########################
## Механизм комнаты без Entity (ATTN_25 §25.6): жалюзи, шторы, дверь, дверцы шкафа
########################
## Данные те же, что у вагонов: MechanismConfig и анимация mech_<id> из Blender (0_ATTN_24 §24.6).
## Исполняет их то же ядро: C_Mechanisms.Mech (позы SLIDE, ROTATE, ANIM) и C_Mechanisms.bind_anim. Состояние t 0..1.
## Никаких сущностей, шины команд и сейва здесь нет: это делает владелец (Room Studio, позже RoomBuilder).

var mech: C_Mechanisms.Mech


## Механизм на узле node (SLIDE, ROTATE: сам node; ANIM: плеер внутри node или сам node). null: привязка не удалась (причина в Output).
## search_root: где искать плеер анимации ANIM (у .glb плеер лежит в корне модели, а не внутри двигающегося узла); пусто: node
static func make(node: Node, cfg: MechanismConfig, owner_name: String, search_root: Node = null) -> RoomMechanism:
	if node == null or cfg == null:
		return null
	var m := C_Mechanisms.Mech.new()
	m.cfg = cfg
	if cfg.actuator == MechanismConfig.Actuator.ANIM:
		if not C_Mechanisms.bind_anim(m, search_root if search_root != null else node, owner_name):
			return null
	elif cfg.actuator == MechanismConfig.Actuator.SLIDE or cfg.actuator == MechanismConfig.Actuator.ROTATE:
		var n3 := node as Node3D
		if n3 == null:
			push_warning("[RoomMechanism] %s: механизм %s: узел '%s' не Node3D" % [owner_name, cfg.id, node.name])
			return null
		m.node = n3
		m.rest = n3.transform
	else:
		push_warning("[RoomMechanism] %s: механизм %s: тип %s в комнате не поддерживается (SLIDE, ROTATE, ANIM)" % [owner_name, cfg.id, cfg.actuator])
		return null
	var rm := RoomMechanism.new()
	rm.mech = m
	return rm


func state() -> float:
	return mech.t


func is_moving() -> bool:
	return mech.is_moving()


## Цель 0..1. instant: сразу в позу, без хода по времени
func set_state(t: float, instant := false) -> void:
	mech.target = clampf(t, 0.0, 1.0)
	if instant:
		mech.t = mech.target
		mech.apply()


## Шаг по времени (duration из MechanismConfig). true: дошли до цели в этом шаге
func tick(dt: float) -> bool:
	if not mech.is_moving():
		return false
	return mech.step(dt)
