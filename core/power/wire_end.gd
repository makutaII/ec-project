class_name WireEnd extends Area3D

# XX claude-wire W5 (новый файл), W6: подсветка при наведении
## Свободный конец провода: ручка, за которую его берут инструментом «Провод» (ЛКМ по концу, продолжить и подключить).
## Лежит на слое power рядом с областью выбора провода. Строит и убирает её C_Wire.

## Какому проводу принадлежит
var wire: C_Wire
## Какой это конец: &"a" (начало ломаной) или &"b" (конец ломаной)
var which: StringName = &"b"
## Наконечник (меш), его C_Wire кладёт сюда
var tip: MeshInstance3D

const COLOR_HOVER := Color(1.0, 0.85, 0.2)


## Подсветка наконечника при наведении инструмента «Провод»: жёлтый со свечением, как у клемм
func set_highlight(on: bool) -> void:
	if tip == null:
		return
	var mat := StandardMaterial3D.new()
	if on:
		mat.albedo_color = COLOR_HOVER
		mat.emission_enabled = true
		mat.emission = COLOR_HOVER
		mat.emission_energy_multiplier = 0.8
	else:
		mat.albedo_color = C_Wire.COLOR_COPPER
		mat.metallic = 0.6
		mat.roughness = 0.35
	tip.material_override = mat
