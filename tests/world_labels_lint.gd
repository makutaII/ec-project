@tool
extends EditorScript

###########################
## Проверка: в игровом мире нет своих меток Label3D (U20a)
###########################
## Запуск: открыть файл, File → Run (Ctrl+Shift+X). Итог в Output: список нарушений или «OK».
## Правило (решение 20.11.2026, ATTN_17 U20a): сообщения инструментов и компонентов в мир не рисуются.
## Новый код говорит через InfoTips (show_lines / clear) или кладет строку в TrackNote: InfoToolTip подхватит ее сам
## и покажет у курсора; Label3D для подписей, ошибок и состояния не создаем.
## Список исключений ниже: каждая запись это известный долг или отладка, с причиной. Новый файл с Label3D
## сюда не дописываем, а переносим на InfoTips. Когда исключение убрано из кода, убери и запись: проверка скажет,
## что запись устарела.

const SCAN_ROOTS := ["res://core/", "res://ui/", "res://data/"]
const SKIP := ["res://addons/", "res://tests/", "res://ui/templates/"]

## Файл -> почему Label3D там пока допустим
const ALLOWED := {
	"res://core/components/power/c_power_device.gd": "U20a.4: состояние устройства на модели (слой питания)",
	"res://core/components/power/c_power_source.gd": "U20a.4: выводы источника на модели (слой питания)",
	"res://core/components/power/c_wire.gd": "U20a.4: метка перекрученного провода",
	"res://data/tracks/power_clip.tscn": "U20a.4: ContourLabel клипа питания",
	"res://data/tracks/G231.tscn": "U20a.4: ContourLabel клипа питания",
	"res://ui/debug/layout_overlay.gd": "отладка: подписи вкладки Layout, не игровой интерфейс",
	"res://core/library/icon_studio/studio_world.gd": "не создает метки: исключает Label3D из габарита иконки",
	"res://core/controllers/info_tips.gd": "в комментарии: описание правила",
	"res://core/components/tracks/track_note.gd": "в комментарии: описание правила",
}


func _run() -> void:
	var found := {}   # путь -> первая найденная строка
	for root in SCAN_ROOTS:
		_scan(root, found)
	var problems: Array[String] = []
	for path: String in found:
		if not ALLOWED.has(path):
			problems.append("%s: %s (перенести на InfoTips, см. шапку файла)" % [path, found[path]])
	for path: String in ALLOWED:
		if not found.has(path):
			problems.append("%s: в списке исключений, но Label3D там уже нет: убрать запись" % path)
	if problems.is_empty():
		print("Метки в мире: OK (исключений %d)" % ALLOWED.size())
		return
	print("Метки в мире: проблем %d" % problems.size())
	for p in problems:
		print("  ", p)


func _scan(dir_path: String, found: Dictionary) -> void:
	for skipped in SKIP:
		if dir_path.begins_with(skipped):
			return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_scan(dir_path + sub + "/", found)
	for f in dir.get_files():
		if not (f.ends_with(".gd") or f.ends_with(".tscn")):
			continue
		var path := dir_path + f
		var text := FileAccess.get_file_as_string(path)
		var at := text.find("Label3D")
		if at >= 0:
			var line_end := text.find("\n", at)
			var line_start := text.rfind("\n", at) + 1
			found[path] = text.substr(line_start, (line_end if line_end >= 0 else text.length()) - line_start).strip_edges()
