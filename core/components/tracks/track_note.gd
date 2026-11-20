class_name TrackNote extends RefCounted

# XX claude-terra 13.1.7 (новый файл)
#######################
## Строки подсказки над призраком или объектом в руке: все подписи и предупреждения трака.
#######################
## U20a.3 (20.11.2026): раньше одна метка Label3D над траком, теперь строки идут в InfoToolTip у курсора (сервис InfoTips).
## API прежний: компоненты держат каждый свою строку (Line) и меняют ее как раньше: text, modulate, visible.
## Строки идут сверху вниз по order. Вид строки (знак и цвет подсказки) берется из modulate: красный это отказ (×),
## желтый предупреждение (!), зеленый норма (●), белый и голубой нейтральная строка.
## position осталось в API для совместимости и не используется: подсказка стоит у курсора.
## Подсказка одна на экран (InfoTips): показывается набор того трака, строки которого менялись последними.
##
##   var _label := TrackNote.line(entity, &"flex", 0)
##   _label.text = "L 12.0"
##   _label.modulate = Color(1.0, 0.35, 0.35)
##   _label.queue_free()     # убрать строку

const META := &"track_note"

var _entity: Node3D
var _lines: Array[Line] = []


## Строка метки. Свойства-сеттеры сами обновляют метку
class Line extends RefCounted:
	var _note: TrackNote
	var key: StringName
	var order := 0
	var text := "":
		set(v):
			if text != v:
				text = v
				_changed()
	var modulate := Color.WHITE:
		set(v):
			if modulate != v:
				modulate = v
				_changed()
	var visible := true:
		set(v):
			if visible != v:
				visible = v
				_changed()
	var position := Vector3(0.0, 6.0, 0.0):
		set(v):
			if position != v:
				position = v
				_changed()

	func _changed() -> void:
		if _note:
			_note._refresh()

	## Убрать строку. Когда строк не осталось, метка удаляется
	func queue_free() -> void:
		if _note:
			var n := _note
			_note = null
			n._remove(self)


## Строка метки у сущности по ключу (создается, если еще нет)
static func line(entity: Node3D, key: StringName, order: int = 0) -> Line:
	var note: TrackNote = entity.get_meta(META) if entity.has_meta(META) else null
	if note == null:
		note = TrackNote.new()
		note._entity = entity
		entity.set_meta(META, note)
	for existing in note._lines:
		if existing.key == key:
			return existing
	var created := Line.new()
	created._note = note
	created.key = key
	created.order = order
	note._lines.append(created)
	note._lines.sort_custom(func(a: Line, b: Line): return a.order < b.order)
	return created


func _remove(l: Line) -> void:
	_lines.erase(l)
	if _lines.is_empty():
		InfoTips.clear(self)
		if is_instance_valid(_entity) and _entity.has_meta(META):
			_entity.remove_meta(META)
		return
	_refresh()


func _refresh() -> void:
	if not is_instance_valid(_entity):
		InfoTips.clear(self)
		return
	var lines: Array = []
	for l in _lines:
		if not l.visible or l.text == "":
			continue
		lines.append(InfoTips.line(l.text, _kind_of(l.modulate)))
	InfoTips.show_lines(self, lines)   # пустой набор снимает подсказку


## Вид строки по цвету, который задал компонент
static func _kind_of(c: Color) -> int:
	if c.r > 0.8 and c.g < 0.55:
		return InfoToolTip.Kind.DANGER   # красный и оранжево-красный
	if c.r > 0.8 and c.b < 0.6:
		return InfoToolTip.Kind.WARN     # желтый
	if c.g > c.r + 0.15 and c.g > c.b:
		return InfoToolTip.Kind.OK       # зеленый
	return InfoToolTip.Kind.INFO         # белый и голубой
