extends CanvasLayer
## Корень интерфейса (ATTN_17 §17.3.1, U8).
## Слои: этот CanvasLayer с Control `HUD` внутри, `Windows` (layer 20), `Toasts` (layer 30).
## Фоторежим и look_lab скрывают только HUD: окна и тосты остаются.

@onready var hud: Control = %HUD


func set_hud_visible(on: bool) -> void:
	hud.visible = on


func is_hud_visible() -> bool:
	return hud.visible


## Тема интерфейса. Control под CanvasLayer тему окна (Window.theme) не наследует, поэтому ставим её
## на корни слоёв: HUD и окна/тосты. null возвращает тему проекта (тёмную). Новые окна в Windows
## и Toasts получают ту же тему при следующем вызове (apply_ui_theme_to)
var _ui_theme: Theme


func set_ui_theme(theme: Theme) -> void:
	_ui_theme = theme
	hud.theme = theme
	for layer_name in [&"Windows", &"Toasts"]:
		var layer := get_node_or_null(NodePath(String(layer_name)))
		if layer == null:
			continue
		for c in layer.get_children():
			apply_ui_theme_to(c)


## Окно, добавленное в Windows или Toasts позже старта, вызывает это после add_child
func apply_ui_theme_to(node: Node) -> void:
	if node is Control:
		(node as Control).theme = _ui_theme
