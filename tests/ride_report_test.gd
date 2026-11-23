@tool
extends EditorScript

###########################
## Проверка текстов сообщений о заезде RideReport (ATTN_27, шаг C6.2)
###########################
## Запуск: открыть файл, File → Run. Сцена не нужна. Итог в Output: «OK» или список ошибок.


func _run() -> void:
	var errors: Array[String] = []

	# Причины: у каждой известной причины свой текст, у неизвестной общий с причиной в скобках
	for r in ["airtime", "side", "stalled", "end_of_track", "tight_curve", "hi speed", "coupler_impact", "obstacle", "track_removed"]:
		var t := RideReport.reason_text(r)
		if t == "" or t.contains("(" + r + ")"):
			errors.append("причина %s не имеет своего текста: «%s»" % [r, t])
	_expect_has(errors, "неизвестная причина", RideReport.reason_text("xyz"), "(xyz)")
	_expect_has(errors, "airtime: слово «оторвался»", RideReport.reason_text("airtime"), "оторвался")
	_expect_has(errors, "side: слово «борт»", RideReport.reason_text("side"), "борт")
	_expect_has(errors, "stalled: слово «энергии»", RideReport.reason_text("stalled"), "энергии")
	_expect_has(errors, "столкновение", RideReport.reason_text("coupler_impact"), "Столкновение")

	# Место: название и доля длины; без трака пусто
	var info := {"reason": "airtime", "speed": 18.4, "load_n": -0.3, "load_l": 0.2, "track": "Выезд с подъёма 15°", "offset": 9.0, "length": 12.0}
	_expect_eq(errors, "место", RideReport.place_text(info), "трак «Выезд с подъёма 15°», 75% длины")
	_expect_eq(errors, "место без трака", RideReport.place_text({"track": ""}), "")
	_expect_eq(errors, "место: доля зажимается", RideReport.place_text({"track": "T", "offset": 50.0, "length": 10.0}), "трак «T», 100% длины")

	# Сообщение: две строки; для airtime прижатие, для side боковая нагрузка, для остальных только скорость и место
	var m := RideReport.message(info)
	_expect_eq(errors, "две строки", m.split("\n").size(), 2)
	_expect_has(errors, "airtime: прижатие в сообщении", m, "прижатие -0.3 g")
	_expect_has(errors, "airtime: скорость", m, "скорость 18")
	var side := info.duplicate()
	side.reason = "side"
	side.load_l = 1.8
	_expect_has(errors, "side: боковая нагрузка", RideReport.message(side), "боковая нагрузка 1.8 g")
	var stalled := {"reason": "stalled", "speed": 0.0, "track": "Подъём 15°", "offset": 5.0, "length": 10.0}
	var ms := RideReport.message(stalled)
	_expect_has(errors, "остановка: место", ms, "50% длины")
	if ms.contains("прижатие") or ms.contains("боковая"):
		errors.append("остановка не должна показывать нагрузки: «%s»" % ms)

	_expect_has(errors, "удар сцепки", RideReport.bump_message(7.4), "скорости 7")

	if errors.is_empty():
		print("OK: тексты сообщений о заезде собираются верно")
	else:
		print("ОШИБКИ (%d):" % errors.size())
		for e in errors:
			print("  - ", e)


func _expect_has(errors: Array[String], name: String, got: String, part: String) -> void:
	if not got.contains(part):
		errors.append("%s: в «%s» нет «%s»" % [name, got, part])


func _expect_eq(errors: Array[String], name: String, got: Variant, want: Variant) -> void:
	if got != want:
		errors.append("%s: получили «%s», ждали «%s»" % [name, got, want])
