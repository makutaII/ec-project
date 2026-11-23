@tool
class_name RideReport extends RefCounted

###########################
## Сообщения о заезде: сход, остановка, столкновение (ATTN_27 §27.8, шаг C6.2)
###########################
## Чистое форматирование текста, без нод. Текст показывает C_RideCar обычным уведомлением LYM.notice (баннер сверху на 3 с).
## Первая строка: что случилось. Вторая: где и при каких нагрузках, чтобы можно было понять, что менять на трассе.
## info: reason, speed, load_n, load_l (в долях g), track (название трака), offset и length (расстояние от начала и длина трака).


## Что случилось, по причине схода или остановки
static func reason_text(reason: String) -> String:
	match reason:
		"airtime":
			return "Вагон оторвался от лотка на горбе: слишком быстро"
		"side":
			return "Вагон вылетел через борт: слишком быстро для поворота (нужен крен или меньше скорость)"
		"stalled":
			return "Вагон остановился: не хватило энергии"
		"end_of_track":
			return "Вагон сошёл с конца трака"
		"tight_curve":
			return "Поворот слишком крутой для вагона"
		"hi speed":
			return "Вагон не удержался на повороте: слишком быстро"
		"coupler_impact":
			return "Столкновение: вагоны ударились"
		"obstacle":
			return "Столкновение: вагон упёрся в препятствие"
		"track_removed":
			return "Трак под вагоном убрали"
	return "Вагон сошёл с трака (%s)" % reason


## Где: название трака и доля длины; пусто, если трак неизвестен
static func place_text(info: Dictionary) -> String:
	var track := str(info.get("track", ""))
	if track == "":
		return ""
	var length := float(info.get("length", 0.0))
	if length > 0.01:
		return "трак «%s», %d%% длины" % [track, roundi(clampf(float(info.get("offset", 0.0)) / length, 0.0, 1.0) * 100.0)]
	return "трак «%s»" % track


## Сообщение о сходе или остановке: две строки
static func message(info: Dictionary) -> String:
	var text := reason_text(str(info.get("reason", "?")))
	var details: Array[String] = []
	var place := place_text(info)
	if place != "":
		details.append(place)
	details.append("скорость %.0f" % float(info.get("speed", 0.0)))
	var reason := str(info.get("reason", ""))
	if reason == "airtime":
		details.append("прижатие %.1f g" % float(info.get("load_n", 1.0)))
	elif reason == "side":
		details.append("боковая нагрузка %.1f g" % float(info.get("load_l", 0.0)))
	return text + "\n" + ", ".join(details)


## Сообщение о мягком ударе сцепки (вагон остался на рельсах): скорость сближения
static func bump_message(v_close: float) -> String:
	return "Столкновение: вагоны ударились на скорости %.0f" % v_close
