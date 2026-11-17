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
##   dry: сила сухой кисти 0..1 (0 выключена); dry_len: сколько пикселей мазка хватает запаса краски;
##   level: с какого уровня правил (paint.level) инструмент доступен.

const ORDER := ["brush", "airbrush", "eraser", "flat", "dry", "sponge", "splatter", "square"]
const DEFAULTS := {
	"name": "", "size": 0.04, "hardness": 0.8, "flow": 1.0, "accumulate": false, "erase": false,
	"tip": "", "shape": "round", "box": Vector2(1.0, 1.0), "rotate": "none", "scatter": 0.0, "jitter": 0.0,
	"spacing": 6.0, "dry": 0.0, "dry_len": 300.0, "level": 2,
}
const PRESETS := {
	"brush": {"name": "Кисть", "size": 0.04, "hardness": 0.8, "flow": 1.0},
	"airbrush": {"name": "Аэрограф", "size": 0.09, "hardness": 0.0, "flow": 0.12, "accumulate": true},
	"eraser": {"name": "Ластик", "size": 0.06, "hardness": 0.5, "flow": 1.0, "erase": true},
	"flat": {"name": "Щётка", "size": 0.06, "hardness": 0.6, "flow": 1.0, "tip": "bristle", "shape": "box",
		"box": Vector2(0.35, 1.0), "rotate": "stroke", "spacing": 5.0, "level": 3},
	"dry": {"name": "Сухая кисть", "size": 0.05, "hardness": 0.5, "flow": 1.0, "tip": "bristle", "rotate": "stroke",
		"spacing": 4.0, "dry": 0.9, "dry_len": 260.0, "level": 3},
	"sponge": {"name": "Губка", "size": 0.06, "hardness": 0.6, "flow": 0.9, "tip": "sponge", "rotate": "random",
		"jitter": 0.25, "spacing": 12.0, "level": 3},
	"splatter": {"name": "Брызги", "size": 0.1, "hardness": 0.9, "flow": 1.0, "tip": "splatter", "rotate": "random",
		"scatter": 0.8, "jitter": 0.5, "spacing": 14.0, "level": 3},
	"square": {"name": "Квадрат", "size": 0.04, "hardness": 0.9, "flow": 1.0, "shape": "box", "rotate": "stroke",
		"spacing": 4.0},
}


## Параметры инструмента (копия): DEFAULTS, поверх них пресет; неизвестный id даёт «Кисть»
static func preset(id: String) -> Dictionary:
	var out: Dictionary = DEFAULTS.duplicate()
	out.merge(PRESETS.get(id, PRESETS["brush"]) as Dictionary, true)
	return out


## Параметры конца штампа для PaintEngine.stamp (opts): текстура, форма, размеры, направление, запас краски, сухая кисть
static func stamp_opts(p: Dictionary, tangent_dir: Vector3, reserve: float) -> Dictionary:
	return {
		"tip": str(p.get("tip", "")), "shape": str(p.get("shape", "round")), "box": p.get("box", Vector2.ONE),
		"tan": tangent_dir, "load": reserve, "dry": float(p.get("dry", 0.0)),
	}


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
