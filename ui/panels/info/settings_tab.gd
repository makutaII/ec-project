class_name InfoSettingsTab extends InfoTab

###########################
## Вкладка «Настройки» (ATTN_17 U5a.4): то, что у объекта можно настраивать
###########################
## Хозяин блоков (как «Вид»): блоки это бывшие вкладки, встроенные через InfoTab.embed, подвал у них общий.
##   Стрелка (InfoSwitchTab), Стол (InfoTableTab), Пульт и провода (InfoDevicesTab), Коммутатор (InfoSwitchboxTab).
## Вкладка видна, если у цели подходит хоть один блок.


func _setup() -> void:
	_blocks_box = make_page("Настройки")
	_embed_blocks([InfoSwitchTab.new(), InfoTableTab.new(), InfoDevicesTab.new(), InfoSwitchboxTab.new()])


func can_show(entity: Entity) -> bool:
	return entity != null and _blocks_can_show(entity)


func _on_bind() -> void:
	footer_clear()
	_bind_blocks()


func _on_unbind() -> void:
	_unbind_blocks()


func refresh() -> void:
	_refresh_blocks()


func components_changed() -> void:
	if target != null:
		_bind_blocks()
		panel.refresh_tab_visibility()
