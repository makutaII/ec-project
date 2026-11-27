class_name TrackStyle extends Resource

########################
## Стиль flex-трака: рельсы, шпалы, балласт. Косметика, растет ВНИЗ от поверхности катания.
########################
## Контракт (общий для всех стилей): колея (rail_x) и высота головки рельса над origin пути (head_height()).
## Все, кто ездит по траку или садится на него, читают только C_Path.head_height(), а он берет число отсюда.
##
## Профили задаются ломаной в осях (x, y):
##  - обход слева направо ПОВЕРХ (по часовой стрелке), днище не задается (его не видно);
##  - ballast_profile: x от оси трака, y от origin пути (низ балласта = 0);
##  - rail_profile: x от оси рельса, y от подошвы рельса.
## Меш шпалы (если задан): origin в центре площади опоры, низ на y = 0, длина вдоль Z, ширина вдоль X.
## Размеры из sleeper_size берутся, только если sleeper_mesh пуст (тогда шпала это BoxMesh).
##
## Примеры:
##  с балластом (по умолчанию): head_height = 0.5 + (0.2 - 0.1) + 0.25 = 0.85
##  без балласта:               ballast_enabled = false, collision_width = 3.0 -> 0.2 + 0.25 = 0.45

## Вдоль пути UV по умолчанию = 1 / TrackMeshBuilder.UV_V_SCALE
const LEGACY_TILE_ALONG := 10.0

@export var id: StringName = &"ballast"
## Стиль «бюджет»: трак строится сценой Blender из `budget_scene` формы (StyleVisualSetting), а не процедурно.
## Остальные поля у такого стиля нужны для высоты рельса (head_height) и стыков. ATTN_17 §17.13, C5, C10
@export var use_scene := false

@export_category("Rails")
## Показывать рельсы. Только визуал: меш рельсов не строится, но rail_profile, rail_x, коллизия головки
## (HeadStaticBody3D) и head_height() остаются как есть, поведение игры не меняется
@export var rail_enabled := true
## Половина колеи (до оси рельса), ю
@export var rail_x := 0.875
@export var rail_profile := PackedVector2Array([
	Vector2(-0.1, 0.0), Vector2(-0.1, 0.25), Vector2(0.1, 0.25), Vector2(0.1, 0.0)])
## null = общий материал рельсов из C_FlexVisual
@export var rail_material: Material
## Размер тайла текстуры рельса, ю: x вдоль пути, y поперек (по длине ломаной профиля, от начала обхода).
## 0 по оси = как раньше (вдоль 10 ю на тайл, поперёк UV растянуты на всю ширину; так нужно текстурам-атласам).
## Плотность полос слоя питания считается с поправкой power_stripe_scale()
@export var rail_uv_tile := Vector2.ZERO
## Повернуть текстуру рельса на 90° (оси UV меняются местами; тайл по-прежнему в ю вдоль и поперёк).
## Слой питания учитывает поворот (swap_uv в шейдере)
@export var rail_uv_rotate := false

@export_category("Sleepers")
## Показывать шпалы. Только визуал: шпалы не расставляются, но размер шпалы (sleeper_dims) по-прежнему
## задаёт base_height() и head_height()
@export var sleeper_enabled := true
## null = BoxMesh размера sleeper_size
@export var sleeper_mesh: Mesh
@export var sleeper_size := Vector3(3.0, 0.2, 0.3)   # ширина, высота, длина вдоль пути
## Зазор между шпалами, ю
@export var sleeper_gap := 0.4
## На сколько шпала вдавлена в балласт, ю (без балласта игнорируется)
@export var sleeper_embed := 0.1
## null = общий материал шпал (для своего sleeper_mesh null оставляет материалы самого меша)
@export var sleeper_material: Material

@export_category("Ballast")
@export var ballast_enabled := true
@export var ballast_profile := PackedVector2Array([
	Vector2(-1.6, 0.0), Vector2(-1.1, 0.5), Vector2(1.1, 0.5), Vector2(1.6, 0.0)])
@export var ballast_material: Material
## Размер тайла текстуры балласта, ю: x вдоль пути, y поперек (по длине ломаной профиля). 0 по оси = как раньше (см. rail_uv_tile)
@export var ballast_uv_tile := Vector2.ZERO
## Повернуть текстуру балласта на 90° (как rail_uv_rotate)
@export var ballast_uv_rotate := false

@export_category("Collision")
## Ширина коллизии основания (балласт/шпалы), ю. Для всех объектов стиля; паспорт объекта (TrackConfig.collision_width > 0) перекрывает её
@export var collision_width := 2.9

@export_category("Surface")
## XX claude-coaster C4: поверхность катания над origin пути, ю. 0 = как раньше: base_height() + rail_height().
## Больше нуля: колёса идут на этой высоте, а высота шпал и рельса в расчёт не входят. Нужно лоткам горок:
## колёса на дне паза, ниже верха бортов ballast_profile. Коллизия основания доходит до этой высоты,
## коллизии рельса нет (боксы рельса остаются крошечными, внутри основания)
@export var surface_height := 0.0
## XX claude-coaster C4: лоток горок. Коллизия рельса заменяется коллизией бортов лотка: два бокса от дна (surface_height)
## до верха бортов из ballast_profile. Нужны surface_height > 0 и профиль, у которого с краёв есть участки выше дна
## (U: два борта; W: крайние стенки, средний выступ в коллизию не входит). Колёса идут по дну, а вагон, сошедший с трака,
## упирается в борта. Рельсы и шпалы лотка выключаются отдельно (rail_enabled, sleeper_enabled): на коллизию они не влияют
@export var trough := false


# ==========================================
# Производные высоты
# ==========================================

## Размер шпалы: AABB меша или sleeper_size. Высота (y) это высота постели рельса: если меш говорит, что рельс стоит
## ниже его верхней точки (метаданные seat_height: площадки-«костыли» выше постели), берётся она
func sleeper_dims() -> Vector3:
	if sleeper_mesh == null:
		return sleeper_size
	var d := sleeper_mesh.get_aabb().size
	var seat := float(sleeper_mesh.get_meta("seat_height", 0.0))
	if seat > 0.0 and seat < d.y:
		d.y = seat
	return d


func sleeper_step() -> float:
	return sleeper_dims().z + sleeper_gap


func ballast_height() -> float:
	return _max_y(ballast_profile) if ballast_enabled else 0.0


## XX claude-car CS3. Половина видимой ширины основания по профилю балласта (наибольший |x|). Нет профиля: половина ширины коллизии.
## От неё считается ложе рельефа дороги; ширина коллизии (collision_width) её не меняет
func ballast_half_width() -> float:
	var hw := 0.0
	for p in ballast_profile:
		hw = maxf(hw, absf(p.x))
	return hw if hw > 0.0 else collision_width * 0.5


## Хотя бы одна часть (балласт, шпалы, рельсы) включена. Стиль, у которого нет ни одной, считается ошибкой
func has_any_part() -> bool:
	return ballast_enabled or sleeper_enabled or rail_enabled


## Индекс поверхности рельсов в меше TrackMeshBuilder.build_mesh: 1 с балластом, 0 без. -1, если рельсы выключены
## (поверхности нет). Слой питания и превью берут индекс только отсюда
func rail_surface_index() -> int:
	if not rail_enabled:
		return -1
	return 1 if ballast_enabled else 0


## Низ шпалы над origin пути
func sleeper_bottom() -> float:
	var embed := sleeper_embed if ballast_enabled else 0.0
	return maxf(ballast_height() - embed, 0.0)


## Низ рельса (верх шпал) над origin пути
func base_height() -> float:
	return sleeper_bottom() + sleeper_dims().y


func rail_height() -> float:
	return _max_y(rail_profile)


func rail_width() -> float:
	var lo := INF
	var hi := -INF
	for p in rail_profile:
		lo = minf(lo, p.x)
		hi = maxf(hi, p.x)
	return hi - lo if hi > lo else 0.2


## Поверхность катания над origin пути. Единственный источник высоты для C_Path.head_height()
func head_height() -> float:
	if surface_height > 0.0:   # XX claude-coaster C4
		return surface_height
	return base_height() + rail_height()


## Борта лотка для коллизии: [левый, правый], каждый Vector3(x от, x до, верх над origin). Берутся из ballast_profile:
## крайние участки, где верх профиля выше поверхности катания. Пусто, если лоток выключен, нет surface_height или балласта,
## у профиля нет двух бортов или нет дна между ними
func trough_boards() -> Array[Vector3]:
	var out: Array[Vector3] = []
	if not trough or surface_height <= 0.0 or not ballast_enabled or ballast_profile.size() < 2:
		return out
	var xs: Array[float] = []
	for p in ballast_profile:
		xs.append(p.x)
	xs.sort()
	var ux: Array[float] = []
	for x in xs:
		if ux.is_empty() or x - ux[ux.size() - 1] > 0.0001:
			ux.append(x)
	var n := ux.size() - 1
	if n < 3:
		return out   # между краями нужен хотя бы борт, дно и борт
	var tops: Array[float] = []
	for i in n:
		tops.append(_profile_top((ux[i] + ux[i + 1]) * 0.5))
	var wall_min := surface_height + 0.01
	var i := 0
	var left_top := 0.0
	while i < n and tops[i] > wall_min:
		left_top = maxf(left_top, tops[i])
		i += 1
	var j := n - 1
	var right_top := 0.0
	while j >= 0 and tops[j] > wall_min:
		right_top = maxf(right_top, tops[j])
		j -= 1
	# i: первый интервал после левого борта, j: последний перед правым. Между ними должно быть дно
	if i == 0 or j == n - 1 or i > j:
		return out
	out.append(Vector3(ux[0], ux[i], left_top))
	out.append(Vector3(ux[j + 1], ux[n], right_top))
	return out


## Верх профиля балласта в точке x (максимум по всем невертикальным отрезкам ломаной, которые покрывают x)
func _profile_top(x: float) -> float:
	var top := 0.0
	for k in ballast_profile.size() - 1:
		var a := ballast_profile[k]
		var b := ballast_profile[k + 1]
		if absf(b.x - a.x) < 0.000001:
			continue
		if x >= minf(a.x, b.x) and x <= maxf(a.x, b.x):
			top = maxf(top, lerpf(a.y, b.y, (x - a.x) / (b.x - a.x)))
	return top


## Во сколько раз плотность полос слоя питания отличается от рельса с UV по умолчанию (тайл 10 ю вдоль пути).
## Шейдер считает полосы по UV.x, поэтому при своём тайле вдоль пути плотность подгоняем, чтобы полосы не менялись
func power_stripe_scale() -> float:
	return rail_uv_tile.x / LEGACY_TILE_ALONG if rail_uv_tile.x > 0.0 else 1.0


func _max_y(p: PackedVector2Array) -> float:
	var m := 0.0
	for v in p:
		m = maxf(m, v.y)
	return m


## XX claude-switch. Стиль с шириной коллизии из паспорта трака (TrackConfig.collision_width).
## width <= 0 или равна ширине стиля: возвращает сам стиль (общий ресурс не копируется). Иначе копия: стиль общий для всех
## траков набора, правим только копию. Поле id копия сохраняет. Стиля нет (st = null), но ширина задана: новый стиль по умолчанию
static func with_collision_width(st: TrackStyle, width: float) -> TrackStyle:
	if width <= 0.0:
		return st
	if st == null:
		var d := TrackStyle.new()
		d.collision_width = width
		return d
	if is_equal_approx(width, st.collision_width):
		return st
	var c := st.duplicate() as TrackStyle
	c.collision_width = width
	return c
