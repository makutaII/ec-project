class_name BuildingSpec extends RefCounted

# XX claude-library L7 (новый файл)
########################
## BuildingSpec. Данные здания для генератора (ATTN_22 §22.7.6, шаг L7)
########################
## Только данные: контур, этажи, крыша, стиль, сид. Геометрию считают BuildingLayout (раскладка) и
## BuildingBuilder (меш). Здание целиком описывается этим словарём (to_dict), поэтому макет переносим без файлов.
## Контуры v1: прямоугольник и L-образный (прямоугольник с вырезанным углом +X,+Z). Все углы прямые.
## Единицы как в игре: 1 ю около 1 м прототипа (house_01: 12 x 8, этаж 3).
## Неизвестные поля словаря не теряются при перезаписи (как у ModelVariant): старая версия игры не стирает данные новой.

const VERSION := 1
const KNOWN := [&"v", &"shape", &"width", &"depth", &"notch_w", &"notch_d", &"floors", &"floor_h", &"roof",
	&"pitch", &"overhang", &"style", &"seed", &"door_wall", &"density", &"overrides"]

enum Shape { RECT, L }
enum Roof { GABLE, FLAT }

const SHAPE_NAMES := {Shape.RECT: "rect", Shape.L: "l"}
const ROOF_NAMES := {Roof.GABLE: "gable", Roof.FLAT: "flat"}

const SIZE_MIN := 4.0
const SIZE_MAX := 24.0
## Ширина и глубина, при которых возможен вырез (иначе L превращается в прямоугольник)
const L_MIN_SIZE := 7.0
const NOTCH_MIN := 2.5
## Что остаётся от стороны после выреза, не меньше
const NOTCH_LEFT_MIN := 3.0
const FLOORS_MIN := 1
const FLOORS_MAX := 4
const FLOOR_H_MIN := 2.4
const FLOOR_H_MAX := 4.0
const PITCH_MIN := 0.25
const PITCH_MAX := 1.0
const OVERHANG_MAX := 1.0
const DENSITY_MIN := 0.5
const DENSITY_MAX := 1.5
const SEED_MAX := 999999

var shape: Shape = Shape.RECT
## Размер вдоль X и вдоль Z, ю
var width := 10.0
var depth := 7.0
## L-образный: размеры выреза в углу (+X, +Z), ю
var notch_w := 4.0
var notch_d := 3.0
var floors := 2
var floor_h := 3.0
var roof: Roof = Roof.GABLE
## Подъём конька к половине пролёта: 0.55 это около 29 градусов
var pitch := 0.55
## Свес крыши над длинными стенами, ю
var overhang := 0.4
var style: StringName = &"brick"
var seed_id := 1
## Номер ребра контура, на котором дверь; -1 автоматически (самая длинная стена, обращённая к -Z)
var door_wall := -1
## Множитель числа окон на стене (1.0 это модуль 2.6 ю на окно)
var density := 1.0
## Переопределения автора («прототип», gen.level 2): зарезервировано, пока хранится как есть
var overrides: Dictionary = {}

var _extra: Dictionary = {}
var _version := VERSION


## Привести значения к допустимым. Вызывать после ручной правки полей; to_dict и from_dict вызывают сами
func sanitize() -> BuildingSpec:
	width = snappedf(clampf(width, SIZE_MIN, SIZE_MAX), 0.1)
	depth = snappedf(clampf(depth, SIZE_MIN, SIZE_MAX), 0.1)
	if width < L_MIN_SIZE or depth < L_MIN_SIZE:
		shape = Shape.RECT
	if shape == Shape.L:
		notch_w = snappedf(clampf(notch_w, NOTCH_MIN, width - NOTCH_LEFT_MIN), 0.1)
		notch_d = snappedf(clampf(notch_d, NOTCH_MIN, depth - NOTCH_LEFT_MIN), 0.1)
	floors = clampi(floors, FLOORS_MIN, FLOORS_MAX)
	floor_h = snappedf(clampf(floor_h, FLOOR_H_MIN, FLOOR_H_MAX), 0.1)
	pitch = snappedf(clampf(pitch, PITCH_MIN, PITCH_MAX), 0.01)
	overhang = snappedf(clampf(overhang, 0.0, OVERHANG_MAX), 0.05)
	density = snappedf(clampf(density, DENSITY_MIN, DENSITY_MAX), 0.05)
	seed_id = clampi(seed_id, 0, SEED_MAX)
	door_wall = maxi(door_wall, -1)
	if not BuildingStyles.has_style(style):
		style = BuildingStyles.DEFAULT
	return self


func is_l() -> bool:
	return shape == Shape.L


func duplicate_spec() -> BuildingSpec:
	return BuildingSpec.from_dict(to_dict())


## Тот же размер и стиль, другой сид (кнопка «Другой вариант»). next_seed детерминирован от старого
func with_next_seed() -> BuildingSpec:
	var s := duplicate_spec()
	s.seed_id = int(hash("%d/%d" % [seed_id, floors]) & 0x7fffffff) % (SEED_MAX + 1)
	if s.seed_id == seed_id:
		s.seed_id = (seed_id + 1) % (SEED_MAX + 1)
	return s


func to_dict() -> Dictionary:
	var d := _extra.duplicate(true)
	d["v"] = maxi(_version, VERSION)
	d["shape"] = SHAPE_NAMES[shape]
	d["width"] = snappedf(width, 0.01)
	d["depth"] = snappedf(depth, 0.01)
	d["notch_w"] = snappedf(notch_w, 0.01)
	d["notch_d"] = snappedf(notch_d, 0.01)
	d["floors"] = floors
	d["floor_h"] = snappedf(floor_h, 0.01)
	d["roof"] = ROOF_NAMES[roof]
	d["pitch"] = snappedf(pitch, 0.01)
	d["overhang"] = snappedf(overhang, 0.01)
	d["style"] = String(style)
	d["seed"] = seed_id
	d["door_wall"] = door_wall
	d["density"] = snappedf(density, 0.01)
	d["overrides"] = overrides.duplicate(true)
	return d


## Читает словарь, как попало записанный: неверные типы и значения заменяются допустимыми, не падает
static func from_dict(d: Dictionary) -> BuildingSpec:
	var s := BuildingSpec.new()
	s._version = int(_num(d, "v", VERSION))
	s.shape = Shape.L if str(d.get("shape", "rect")) == "l" else Shape.RECT
	s.width = _num(d, "width", s.width)
	s.depth = _num(d, "depth", s.depth)
	s.notch_w = _num(d, "notch_w", s.notch_w)
	s.notch_d = _num(d, "notch_d", s.notch_d)
	s.floors = int(_num(d, "floors", s.floors))
	s.floor_h = _num(d, "floor_h", s.floor_h)
	s.roof = Roof.FLAT if str(d.get("roof", "gable")) == "flat" else Roof.GABLE
	s.pitch = _num(d, "pitch", s.pitch)
	s.overhang = _num(d, "overhang", s.overhang)
	s.style = StringName(str(d.get("style", String(s.style))))
	s.seed_id = int(_num(d, "seed", s.seed_id))
	s.door_wall = int(_num(d, "door_wall", s.door_wall))
	s.density = _num(d, "density", s.density)
	var ov: Variant = d.get("overrides")
	if ov is Dictionary:
		s.overrides = (ov as Dictionary).duplicate(true)
	for k in d:
		if not KNOWN.has(StringName(str(k))):
			s._extra[k] = d[k]
	return s.sanitize()


## Здание из исполнения сущности (Entity.variant["building"]). Нет ключа или не словарь: здание по умолчанию
static func from_variant(variant: Dictionary) -> BuildingSpec:
	var b: Variant = variant.get("building")
	if b is Dictionary:
		return from_dict(b as Dictionary)
	return BuildingSpec.new().sanitize()


## Подпись для сравнения и кэша: одинаковые здания дают одинаковую строку
func signature() -> String:
	return JSON.stringify(to_dict(), "", true)


func equals(other: BuildingSpec) -> bool:
	return other != null and signature() == other.signature()


static func _num(d: Dictionary, key: String, fallback: float) -> float:
	var v: Variant = d.get(key)
	if v is int or v is float:
		var f := float(v)
		if is_finite(f):
			return f
	return fallback
