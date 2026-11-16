class_name PaintData extends RefCounted

# XX claude-library (новый файл)
########################
## PaintData. Данные покраски внутри исполнения (ModelVariant.paint), схема v2 (ATTN_22 §22.7.2.1, шаг L3)
########################
## paint = {"v": 2, "layers": [слой, ...]}. Слой «Грунт» (id base) задаёт цвет по зонам; слои с текстурой (кисть)
## добавляются шагами C2 в тот же список, формат не меняется.
## Зона это целая поверхность (surface) меша или вся модель: id зоны "all" либо "<имя меша>#<номер поверхности>".
## Значение зоны: {"color": "#rrggbb", "finish": "keep|matte|satin|gloss|metal", "cover": bool}.
## cover: кроющая краска (закрывает рисунок модели) или лессировка (цвет умножается на рисунок модели).
## Словарь paint изменяется на месте: функции берут его по ссылке.

const VERSION := 2
const BASE_ID := "base"
const ALL := "all"

## Отделка: «keep» не трогает шероховатость и металличность модели
const FINISHES := {
	"keep": {"name": "Как у модели"},
	"matte": {"name": "Матовая", "rough": 0.9, "metal": 0.0},
	"satin": {"name": "Полуматовая", "rough": 0.55, "metal": 0.0},
	"gloss": {"name": "Глянец", "rough": 0.2, "metal": 0.0},
	"metal": {"name": "Металлик", "rough": 0.3, "metal": 0.85},
}
const FINISH_ORDER := ["keep", "matte", "satin", "gloss", "metal"]


static func new_paint() -> Dictionary:
	return {"v": VERSION, "layers": []}


## Слой «Грунт». create: создать, если его нет. Без create и без слоя вернёт пустой словарь
static func base_layer(paint: Dictionary, create := false) -> Dictionary:
	var layers: Variant = paint.get("layers")
	if layers is Array:
		for l in layers:
			if l is Dictionary and str(l.get("id", "")) == BASE_ID:
				return l
	if not create:
		return {}
	if not (layers is Array):
		layers = []
		paint["layers"] = layers
	paint["v"] = VERSION
	var layer := {
		"id": BASE_ID, "name": "Грунт", "coverage": "zones", "zones": {},
		"blend": "normal", "opacity": 1.0, "relief": 0.0, "visible": true,
	}
	(layers as Array).append(layer)
	return layer


## Зоны грунта: id -> {color, finish, cover}. Неверные записи пропускаются, скрытый слой даёт пусто
static func zones(paint: Dictionary) -> Dictionary:
	var out := {}
	var base := base_layer(paint)
	if base.is_empty() or not bool(base.get("visible", true)):
		return out
	var z: Variant = base.get("zones")
	if z is Dictionary:
		for k in z:
			var spec := _normalize(z[k])
			if not spec.is_empty():
				out[str(k)] = spec
	return out


static func zone_spec(paint: Dictionary, zone_id: String) -> Dictionary:
	return zones(paint).get(zone_id, {})


static func set_zone(paint: Dictionary, zone_id: String, color: Color, finish := "keep", cover := true) -> void:
	var base := base_layer(paint, true)
	if not (base.get("zones") is Dictionary):
		base["zones"] = {}
	var z: Dictionary = base["zones"]
	z[zone_id] = {
		"color": "#" + color.to_html(false),
		"finish": finish if FINISHES.has(finish) else "keep",
		"cover": cover,
	}


static func clear_zone(paint: Dictionary, zone_id: String) -> void:
	var base := base_layer(paint)
	if base.get("zones") is Dictionary:
		(base["zones"] as Dictionary).erase(zone_id)


static func clear_all(paint: Dictionary) -> void:
	var base := base_layer(paint)
	if base.get("zones") is Dictionary:
		(base["zones"] as Dictionary).clear()


static func is_empty(paint: Dictionary) -> bool:
	return zones(paint).is_empty()


## Запись зоны: старая форма (строка с цветом) или словарь
static func _normalize(v: Variant) -> Dictionary:
	if v is String:
		return {"color": v, "finish": "keep", "cover": true}
	if v is Dictionary:
		var d: Dictionary = v
		var color := str(d.get("color", ""))
		if color == "":
			return {}
		var finish := str(d.get("finish", "keep"))
		return {"color": color, "finish": finish if FINISHES.has(finish) else "keep", "cover": bool(d.get("cover", true))}
	return {}


# ==========================================
# СЛОИ С ТЕКСТУРОЙ (кисть, C2.1b)
# ==========================================
## Слой кисти: {"id": "p1", "name": "Кисть", "coverage": "texture", "mesh": имя опорного меша, "meshes": [имена всех мешей
## общего атласа], "res": 1024, "file": "p1.png", "premultiplied": true, "blend": "normal", "opacity": 1.0, "relief": 0.0,
## "visible": true}. Краска лежит в PNG (RGBA, общий атлас UV2 мешей слоя, цвет sRGB, умноженный на альфу). Старые слои
## без поля meshes относятся к одному мешу mesh. В файле исполнения слой ссылается на PNG (file); в сейве макета и
## у сущности в игре PNG лежит внутри словаря (поле data, PackedByteArray), поэтому макет не зависит от user://.
## data в JSON не пишется никогда (VariantIO вырезает).

const TEXTURE_LAYER_ID := "p1"


## Слои с текстурой (ссылки на словари внутри paint)
static func texture_layers(paint: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var layers: Variant = paint.get("layers")
	if layers is Array:
		for l in layers:
			if l is Dictionary and str(l.get("coverage", "")) == "texture":
				out.append(l)
	return out


static func has_texture_layers(paint: Dictionary) -> bool:
	return not texture_layers(paint).is_empty()


## Нет ни заливки зон, ни слоёв кисти
static func is_blank(paint: Dictionary) -> bool:
	return is_empty(paint) and not has_texture_layers(paint)


## Создаёт или заменяет слой кисти. file: имя PNG рядом с исполнением; data: байты PNG внутри словаря (сейв, игра);
## meshes: имена всех мешей общего атласа (пусто: слой только на mesh_name)
static func set_texture_layer(paint: Dictionary, id: String, mesh_name: String, res: int, file := "", data := PackedByteArray(), meshes: Array = []) -> Dictionary:
	remove_texture_layer(paint, id)
	var layers: Variant = paint.get("layers")
	if not (layers is Array):
		layers = []
		paint["layers"] = layers
	paint["v"] = VERSION
	var layer := {
		"id": id, "name": "Кисть", "coverage": "texture", "mesh": mesh_name, "res": res, "premultiplied": true,
		"blend": "normal", "opacity": 1.0, "relief": 0.0, "visible": true,
	}
	if not meshes.is_empty():
		var names: Array = []
		for m in meshes:
			names.append(str(m))
		layer["meshes"] = names
	if file != "":
		layer["file"] = file
	if not data.is_empty():
		layer["data"] = data
	(layers as Array).append(layer)
	return layer


## Имена мешей, на которые ложится слой: поле meshes, а у старых слоёв один меш из mesh
static func layer_meshes(layer: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var list: Variant = layer.get("meshes")
	if list is Array:
		for m in list:
			if str(m) != "":
				out.append(str(m))
	if out.is_empty() and str(layer.get("mesh", "")) != "":
		out.append(str(layer["mesh"]))
	return out


static func remove_texture_layer(paint: Dictionary, id: String) -> void:
	var layers: Variant = paint.get("layers")
	if not (layers is Array):
		return
	var arr: Array = layers
	for i in range(arr.size() - 1, -1, -1):
		var l: Variant = arr[i]
		if l is Dictionary and str(l.get("coverage", "")) == "texture" and str(l.get("id", "")) == id:
			arr.remove_at(i)
