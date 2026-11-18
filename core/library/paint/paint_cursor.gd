class_name PaintCursor extends Node3D

# XX claude-library (новый файл)
########################
## PaintCursor. Контур кисти на поверхности модели (ATTN_22 §22.7.2.1)
########################
## Контур это декали, проецируемые на модель под курсором, поэтому он огибает кривизну и не зависит от вида:
##   внешнее кольцо: размер штампа (круг или прямоугольник конца кисти, развёрнутый по направлению мазка);
##   внутреннее кольцо: граница полной плотности (жёсткость); у мягких кистей (аэрограф) его нет;
##   тонкое круглое кольцо: область разброса штампов (брызги).
## Кольцо светлое с тёмной обводкой: видно на любой поверхности и с любым цветом краски; у ластика красноватое.
## Узел стоит в World3D студии (дочерний узел StudioWorld). Позиции и направления в мировых координатах.

const TEX_SIZE := 256
const LINE_CENTER := 0.955          ## середина линии кольца в долях полуразмера картинки
const MIN_HARDNESS_RING := 0.1      ## внутреннее кольцо рисуется при жёсткости от этого значения
const MAX_HARDNESS_RING := 0.95     ## ... до этого (у почти твёрдых оно совпало бы с внешним)

static var _textures := {}          # "round" / "box" -> ImageTexture

var outer: Decal
var inner: Decal
var scatter_ring: Decal
var _shape := ""


func _init() -> void:
	name = "PaintCursor"
	outer = _make_decal()
	inner = _make_decal()
	scatter_ring = _make_decal()
	hide_cursor()


func _make_decal() -> Decal:
	var d := Decal.new()
	d.normal_fade = 0.2
	d.upper_fade = 0.3
	d.lower_fade = 0.3
	d.emission_energy = 1.0
	add_child(d)
	return d


## Текстура кольца: "round" круг, "box" прямоугольник (расстояние по максимальной оси). Светлая линия с тёмной обводкой
static func ring_texture(shape: String) -> ImageTexture:
	var key := "box" if shape == "box" else "round"
	if not _textures.has(key):
		_textures[key] = ImageTexture.create_from_image(ring_image(key))
	return _textures[key]


static func ring_image(shape: String) -> Image:
	var px := PackedByteArray()
	px.resize(TEX_SIZE * TEX_SIZE * 4)
	var half := TEX_SIZE * 0.5
	for y in TEX_SIZE:
		for x in TEX_SIZE:
			var dx := (x + 0.5 - half) / half
			var dy := (y + 0.5 - half) / half
			var d := maxf(absf(dx), absf(dy)) if shape == "box" else sqrt(dx * dx + dy * dy)
			var off := absf(d - LINE_CENTER)
			var line := 1.0 - smoothstep(0.012, 0.022, off)         # светлая линия
			var halo := (1.0 - smoothstep(0.028, 0.05, off)) * 0.6   # тёмная обводка вокруг
			var i := (y * TEX_SIZE + x) * 4
			var v := int(line * 255.0 + 0.5)
			px[i] = v
			px[i + 1] = v
			px[i + 2] = v
			px[i + 3] = int(maxf(line, halo) * 255.0 + 0.5)
	return Image.create_from_data(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8, px)


## Показать контур в точке pos мира: normal поверхности, tangent направление конца (вдоль мазка), radius штампа в мире,
## p параметры инструмента (shape, box, hardness, scatter, erase). Узел уже в дереве
func show_at(pos: Vector3, normal: Vector3, tangent: Vector3, radius: float, p: Dictionary) -> void:
	var n := normal.normalized()
	var t := tangent - n * tangent.dot(n)
	if t.length() < 0.00001:
		t = n.cross(Vector3.RIGHT) if absf(n.dot(Vector3.RIGHT)) < 0.9 else n.cross(Vector3.UP)
	t = t.normalized()
	var basis := Basis(t, n, t.cross(n))        # x вдоль конца, y по нормали (ось проекции декали), z поперёк
	var shape := str(p.get("shape", "round"))
	var box: Vector2 = p.get("box", Vector2.ONE)
	var hardness := float(p.get("hardness", 0.5))
	var scatter := float(p.get("scatter", 0.0))
	var r := maxf(radius, 0.0005)
	var depth := maxf(r * 1.5, 0.002)
	var tint := Color(1.0, 0.55, 0.55) if bool(p.get("erase", false)) else Color.WHITE

	if shape != _shape:
		_shape = shape
		var tex := ring_texture(shape)
		for d in [outer, inner]:
			(d as Decal).texture_albedo = tex
			(d as Decal).texture_emission = tex
	if scatter_ring.texture_albedo == null:
		var rt := ring_texture("round")
		scatter_ring.texture_albedo = rt
		scatter_ring.texture_emission = rt

	global_transform = Transform3D(basis, pos)
	_place(outer, Vector3(2.0 * r * box.x, depth, 2.0 * r * box.y), tint, 1.0, true)
	var ring := hardness >= MIN_HARDNESS_RING and hardness <= MAX_HARDNESS_RING
	_place(inner, Vector3(2.0 * r * box.x * hardness, depth, 2.0 * r * box.y * hardness), tint, 0.55, ring)
	var wide := 2.0 * r * (1.0 + scatter)
	_place(scatter_ring, Vector3(wide, depth, wide), tint, 0.4, scatter > 0.0)
	visible = true


func _place(d: Decal, size: Vector3, tint: Color, alpha: float, shown: bool) -> void:
	d.visible = shown
	d.size = size
	d.modulate = Color(tint.r, tint.g, tint.b, alpha)


func hide_cursor() -> void:
	visible = false
