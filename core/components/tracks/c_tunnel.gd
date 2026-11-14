class_name C_Tunnel extends Component

# XX claude-terra (новый файл)
#######################
## State. Флаг: трак тоннельный (13.1.3, T6). Наличие компонента и есть флаг allow_underground.
#######################
## Тоннельный трак может уходить под лист пенопласта:
##  - C_Path.underground_depth не считает листы землей (стол остается землей, ниже стола трак не идет);
##  - лист над таким траком прорезается тоннелем с кровлей (C_TerrainLayer.recompute_auto_cuts), а не
##    канавой во всю высоту: над тоннелем остается свод, высота прохода TunnelClearance над головкой рельса.
## Включается клавишей U: в BuildTool на призраке (режим запоминается), в SelectTool на выбранном траке.
## Можно задать и в .tres трака: TrackConfig.allow_underground.
## Сохраняется (save_data) и переходит из призрака в настоящий объект (on_clone_state_to).
## Индикатор: метка TUNNEL над траком (Label3D, как метка flex).

const LABEL_PIXEL_SIZE := 0.0015
const LABEL_FONT_SIZE := 32

var _label: TrackNote.Line   # строка общей метки TrackNote
## 13.13 K5. Стиль портала (TunnelPortal.STYLES): пусто = нет. Рамку рисует лист в устье выреза, здесь хранится только стиль
var portal: StringName = TunnelPortal.STYLE_NONE


func _init() -> void:
	is_state = true


func on_added() -> void:
	name = 'C_Tunnel'
	_ensure_label()
	_place_label()
	# слушатели (C_TrackSupport) отложат пересчет листов: сейчас компонент еще (или уже) в Entity
	entity.send_event("on_tunnel_changed", {})


func on_removed() -> void:
	if _label and is_instance_valid(_label):
		_label.queue_free()
	_label = null
	entity.send_event("on_tunnel_changed", {})


## flex поменял форму: метка остается над серединой кривой
func on_curve_changed(_d: Dictionary) -> void:
	_place_label()


## Призрак -> настоящий объект: флаг и стиль портала переходят вместе с состоянием
func on_clone_state_to(data: Dictionary) -> void:
	var target: Entity = data.target
	if target == null:
		return
	var t := target.get_comp(C_Tunnel) as C_Tunnel
	if t == null:
		t = C_Tunnel.new()
		target.add_component(t)
	t.portal = portal


## XX claude-terra 13.13 K5. Событие: следующий стиль портала (нет, бетон, камень). Шлёт SelectTool на выбранном траке.
## Листы пересчитают устья по on_tunnel_changed
func on_portal_cycle(_d: Dictionary) -> void:
	portal = TunnelPortal.next_style(portal)
	_update_label()
	entity.send_event("on_tunnel_changed", {})


func _ensure_label() -> void:
	if _label:
		return
	_label = TrackNote.line(entity, &"tunnel", 20)   # самой нижней строкой
	_update_label()
	_label.modulate = Color(0.45, 0.8, 1.0)


func _update_label() -> void:
	if _label:
		_label.text = "TUNNEL" if portal == TunnelPortal.STYLE_NONE else "TUNNEL · портал: %s" % TunnelPortal.NAMES.get(portal, "?")


func _place_label() -> void:
	if not _label:
		return
	var mid := Vector3.ZERO
	var path := get_comp(C_Path) as C_Path
	if path and path.curve and path.path_node:
		mid = path.path_node.position + path.curve.sample_baked(path.curve.get_baked_length() * 0.5)
	_label.position = mid + Vector3(0.0, 4.0, 0.0)


## --- Сейв ---
## Без save_data флаг после загрузки пропал бы: SaveManager досоздает такой компонент сам
func save_data() -> Dictionary:
	if portal == TunnelPortal.STYLE_NONE:
		return {"on": true}
	return {"on": true, "portal": String(portal)}


## Старые сейвы без поля portal: портала нет. Неизвестный стиль тоже сводится к «нет»
func load_data(data: Dictionary) -> void:
	var p := StringName(String(data.get("portal", "")))
	portal = p if TunnelPortal.STYLES.has(p) else TunnelPortal.STYLE_NONE
	_update_label()
