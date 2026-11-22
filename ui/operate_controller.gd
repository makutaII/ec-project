class_name OperateController extends Node

########################
##    OperateController - UI
## 💡 Адаптер режима OPERATE для ToolbarController 💡
########################
## Кнопки и анимация теперь в ToolbarController. Здесь осталось то, что знает только Operate:
## какие объекты показывать (каталог) и что делать с выбранным (2D контроллер питания отдаем DCPanelHost, остальное в стройку).

func _ready() -> void:
	%ToolbarController.register_mode(&"operate", EntityCatalogProvider.new(&"operate"), on_object_selected)


## ⚡Приемник: объект из кнопки каталога
func on_object_selected(setting: Resource) -> void:
	if setting is DCControllerSetting and setting.tag == &'2d':
		# 2D-контроллер это обычный объект каталога, но он не ставится на стол: им владеет DCPanelHost (U15)
		(%DCPanelHost as DCPanelHost).place(setting)
	elif setting is EntitySetting: # 3D-пульт и инструмент «Провод»: тот же путь, что у стройки (призрак, клик)
		var tc := get_tree().get_first_node_in_group(&"tool_controller") as ToolController
		if tc:
			tc.select_build_object(setting)
