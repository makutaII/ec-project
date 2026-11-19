class_name PaintBrushes extends RefCounted

# XX claude-library (новый файл)
########################
## PaintBrushes. Пресеты инструментов кисти (ATTN_22 §22.7.2.1, шаги C2.1, C2.2)
########################
## Инструмент это набор параметров штампа, а не отдельный код: новый инструмент из списка автора добавляется записью.
## Параметры (всё, чего нет в пресете, берётся из DEFAULTS):
##   size: доля наибольшего габарита модели; hardness: доля радиуса, где штамп полный (0 мягкий, как у аэрографа);
##   flow: плотность одного штампа; accumulate: пока кнопка удержана на месте, штамп повторяется каждый кадр;
##   erase: штамп стирает краску слоя вместо нанесения;
##   tip: текстура конца из PaintTips ("" без текстуры); shape: "round" круг или "box" прямоугольник;
##   box: полуразмеры конца (вдоль штриха, поперёк) в долях радиуса; rotate: "none", "stroke" (по направлению мазка),
##   "random" (случайный угол на каждый штамп), "fixed" (по оси Y модели); scatter: разброс центра штампа в долях радиуса;
##   jitter: случайность размера и угла 0..1; spacing: шаг штампов вдоль мазка, пиксели экрана;
##   decal_tool: инструмент «Декаль»: клик ставит картинку (decal, id из PaintDecals) с поворотом decal_angle (градусы),
##   зеркалом decal_mirror и цветом палитры decal_tint; size это полуразмер большей стороны; single: один штамп на нажатие;
##   relief: 1 красить только по рельефу, выступы и светлые кромки (сухая кисть), -1 только впадины и тёмные тени (смывка),
##   0 без рельефа; relief_sens: чувствительность к рельефу; relief_width: ширина перехода в пикселях слоя;
##   dry: сила «сухой щетины» 0..1 по запасу краски (0 выключена; пресеты не используют); dry_len: длина запаса, пиксели;
##   sample: образец из PaintSamples ("" плоский цвет; с образцом цвет берётся из него); sample_size: размер повтора
##   образца в долях наибольшего габарита модели; sample_random: каждый мазок берёт свой участок образца (иначе рисунок
##   привязан к модели и при каждом мазке «проявляется» одним и тем же);
##   level: с какого уровня правил (paint.level) инструмент доступен.

const ORDER := ["brush", "airbrush", "eraser", "flat", "dry", "wash", "sponge", "splatter", "square", "decal"]
const DEFAULTS := {
	"name": "", "size": 0.04, "hardness": 0.8, "flow": 1.0, "accumulate": false, "erase": false,
	"tip": "", "shape": "round", "box": Vector2(1.0, 1.0), "rotate": "none", "scatter": 0.0, "jitter": 0.0,
	"spacing": 6.0, "dry": 0.0, "dry_len": 300.0, "relief": 0.0, "relief_sens": 1.0, "relief_width": 3.0,
	"sample": "", "sample_size": 0.25, "sample_random": true,
	"decal_tool": false, "single": false, "decal": "", "decal_angle": 0.0, "decal_mirror": false, "decal_tint": true, "level": 2,
}
const PRESETS := {
	"brush": {"name": "Кисть", "size": 0.04, "hardness": 0.8, "flow": 1.0},
	"airbrush": {"name": "Аэрограф", "size": 0.09, "hardness": 0.0, "flow": 0.12, "accumulate": true},
	"eraser": {"name": "Ластик", "size": 0.06, "hardness": 0.5, "flow": 1.0, "erase": true},
	"flat": {"name": "Щётка", "size": 0.06, "hardness": 0.6, "flow": 1.0, "tip": "bristle", "shape": "box",
		"box": Vector2(0.35, 1.0), "rotate": "stroke", "spacing": 5.0, "level": 3},
	"dry": {"name": "Сухая кисть", "size": 0.05, "hardness": 0.6, "flow": 0.9, "relief": 1.0, "spacing": 5.0, "level": 3},
	"wash": {"name": "Смывка", "size": 0.06, "hardness": 0.6, "flow": 0.6, "relief": -1.0, "spacing": 6.0, "level": 3},
	"sponge": {"name": "Губка", "size": 0.06, "hardness": 0.6, "flow": 0.9, "tip": "sponge", "rotate": "random",
		"jitter": 0.25, "spacing": 12.0, "level": 3},
	"splatter": {"name": "Брызги", "size": 0.1, "hardness": 0.9, "flow": 1.0, "tip": "splatter", "rotate": "random",
		"scatter": 0.8, "jitter": 0.5, "spacing": 14.0, "level": 3},
	"square": {"name": "Квадрат", "size": 0.04, "hardness": 0.9, "flow": 1.0, "shape": "box", "rotate": "stroke",
		"spacing": 4.0},
	"decal": {"name": "Декаль", "size": 0.08, "hardness": 0.99, "flow": 1.0, "decal_tool": true, "single": true, "decal": "star",
		"level": 3},
}


## Параметры инструмента (копия): DEFAULTS, поверх них пресет; неизвестный id даёт «Кисть»
static func preset(id: String) -> Dictionary:
	var out: Dictionary = DEFAULTS.duplicate()
	out.merge(PRESETS.get(id, PRESETS["brush"]) as Dictionary, true)
	return out


## Параметры штампа для PaintEngine.stamp (opts): текстура конца, форма, размеры, направление, запас краски, сухая кисть, образец
static func stamp_opts(p: Dictionary, tangent_dir: Vector3, reserve: float) -> Dictionary:
	var opts := {
		"tip": str(p.get("tip", "")), "shape": str(p.get("shape", "round")), "box": p.get("box", Vector2.ONE),
		"tan": tangent_dir, "load": reserve, "dry": float(p.get("dry", 0.0)),
		"sample": str(p.get("sample", "")), "sample_size": float(p.get("sample_size", 0.25)),
		"relief": float(p.get("relief", 0.0)), "relief_sens": float(p.get("relief_sens", 1.0)),
	}
	if bool(p.get("decal_tool", false)):
		opts["decal"] = str(p.get("decal", ""))
		opts["decal_mirror"] = bool(p.get("decal_mirror", false))
		opts["decal_tint"] = bool(p.get("decal_tint", true))
	return opts


## Направление «вправо» по картинке декали на поверхности с нормалью normal: «вверх» по картинке это ось Y модели
## (у горизонтальной поверхности ось X, см. _fixed_tangent), повёрнутая вокруг нормали на angle_deg против часовой
## стрелки (если смотреть на поверхность). Единичный вектор, перпендикулярный нормали
static func decal_right(normal: Vector3, angle_deg: float) -> Vector3:
	var n := normal.normalized()
	var up := _fixed_tangent(n).rotated(n, deg_to_rad(angle_deg))
	return up.cross(n).normalized()


## Запас краски 0..1 после пройденных по мазку пикселей: убывает линейно до нуля на dry_len. Без сухой кисти всегда 1
static func load_left(p: Dictionary, travelled_px: float) -> float:
	if float(p.get("dry", 0.0)) <= 0.0:
		return 1.0
	return clampf(1.0 - travelled_px / maxf(float(p.get("dry_len", 300.0)), 1.0), 0.0, 1.0)


## Направление конца в касательной плоскости (единичный вектор, перпендикулярный нормали).
## stroke: вдоль смещения штриха на модели (move), без движения прежнее направление (last), иначе по оси Y;
## random: случайный угол; fixed и none: по оси Y модели. jitter добавляет случайный поворот до 45 градусов
static func tangent(normal: Vector3, mode: String, move: Vector3, rng: RandomNumberGenerator, jitter := 0.0, last := Vector3.ZERO) -> Vector3:
	var n := normal.normalized()
	var t := _fixed_tangent(n)
	match mode:
		"stroke":
			var m := move - n * move.dot(n)
			if m.length() > 0.00001:
				t = m.normalized()
			else:
				var l := last - n * last.dot(n)
				if l.length() > 0.00001:
					t = l.normalized()
		"random":
			t = t.rotated(n, rng.randf() * TAU)
	return jittered(n, t, jitter, rng)


## Направление t, повёрнутое вокруг нормали n на случайный угол до jitter * 45 градусов
static func jittered(n: Vector3, t: Vector3, jitter: float, rng: RandomNumberGenerator) -> Vector3:
	if jitter <= 0.0 or rng == null:
		return t.normalized()
	return t.rotated(n.normalized(), rng.randf_range(-1.0, 1.0) * jitter * PI * 0.25).normalized()


static func _fixed_tangent(n: Vector3) -> Vector3:
	var ref := Vector3.UP if absf(n.y) < 0.95 else Vector3.RIGHT
	return (ref - n * ref.dot(n)).normalized()


## Смещение центра штампа в касательной плоскости: случайная точка круга радиуса radius * scatter (0: нет смещения)
static func scatter_offset(normal: Vector3, tan_dir: Vector3, radius: float, scatter: float, rng: RandomNumberGenerator) -> Vector3:
	if scatter <= 0.0:
		return Vector3.ZERO
	var n := normal.normalized()
	var b := n.cross(tan_dir)
	var ang := rng.randf() * TAU
	var dist := sqrt(rng.randf()) * radius * scatter
	return tan_dir * (cos(ang) * dist) + b * (sin(ang) * dist)
