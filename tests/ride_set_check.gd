@tool
extends EditorScript

###########################
## Сводка по набору траков горок (ATTN_27)
###########################
## Запуск: открыть файл, File → Run. Сцена не нужна. Читает все RideTrackConfig из data/coaster/objects/, печатает таблицу
## (длина, уклон и крен в начале и конце, набор высоты) и какие траки могут идти друг за другом вперёд без поворота
## (конец A стыкуется с началом B: одинаковый уклон и крен в пределах допуска). Справочный скрипт: ничего не меняет и ошибок не
## выдаёт, только предупреждения о повторах ключей и порядка сортировки.

const DIR := "res://data/coaster/objects/"
const PITCH_TOL := 0.5   # градусы: излом уклона между A и B (в игре допуск шире, 6°, но пара без излома лучше)
const BANK_TOL := 3.0    # градусы: Global.settings.joint_bank_max_deg по умолчанию


func _run() -> void:
	var rows: Array[Dictionary] = []
	for f in DirAccess.get_files_at(DIR):
		if not f.ends_with(".tres"):
			continue
		var res := load(DIR + f)
		var cfg = _find_cfg(res)
		if cfg == null:
			continue
		var L: float = cfg.get("length")
		var p0: float = cfg.get("pitch_start_deg")
		var p1: float = cfg.get("pitch_end_deg")
		var turn: float = cfg.get("deg")
		var r0: float = cfg.get("roll_start_deg")
		var r1: float = cfg.get("roll_end_deg")
		var curve := RideShape.build(L, p0, p1, turn, r0, r1)
		var end := curve.get_point_position(curve.get_point_count() - 1)
		rows.append({"file": f.get_basename(), "key": str(res.get("key")), "sort": res.get("sort_order"),
			"L": L, "p0": p0, "p1": p1, "r0": r0, "r1": r1, "turn": turn, "dy": end.y})

	if rows.is_empty():
		print("Траков с RideTrackConfig в %s не найдено" % DIR)
		return
	rows.sort_custom(func(a, b): return a.file < b.file)
	print("Траки горок: %d" % rows.size())
	print("%-26s %6s %12s %12s %7s %7s" % ["файл", "длина", "уклон °", "крен °", "поворот", "набор"])
	for r in rows:
		print("%-26s %6.1f %5.1f → %-5.1f %5.1f → %-5.1f %7.1f %7.2f" % [r.file, r.L, r.p0, r.p1, r.r0, r.r1, r.turn, r.dy])

	print("\nМогут идти вперёд друг за другом (конец A → начало B):")
	for a in rows:
		var next: Array[String] = []
		for b in rows:
			if absf(a.p1 - b.p0) <= PITCH_TOL and absf(a.r1 - b.r0) <= BANK_TOL:
				next.append(b.file)
		print("  %s → %s" % [a.file, ", ".join(next) if not next.is_empty() else "(нет)"])

	# Предупреждения: повтор ключа и повтор порядка сортировки внутри тега
	var keys := {}
	for r in rows:
		if keys.has(r.key):
			print("ПРЕДУПРЕЖДЕНИЕ: ключ %s у двух файлов: %s и %s" % [r.key, keys[r.key], r.file])
		keys[r.key] = r.file
	print("Готово.")


## RideTrackConfig из компонентов объекта: у ресурса-заглушки свойства читаются через get()
func _find_cfg(res: Resource) -> Variant:
	var comps = res.get("components")
	if comps == null:
		return null
	for c in comps:
		if c == null:
			continue
		var cfg = c.get("object_config")
		if cfg != null and cfg.get("pitch_start_deg") != null:
			return cfg
	return null
