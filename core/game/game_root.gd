extends Node
class_name GameRoot

##########################
##
## GameRoot ничего не делает 
##
###########################

## 💡 Глобальные переменные в Global - globals.gd

## 💡 В идеале - ТОЛЬКО связывает системы, больше не синглтон пока!
#Entity (объект) = контейнер компонентов
#Components = данные + логика (по месту)
#Controllers = orchestration (высокоуровневая логика)


####################################################
#СПРАВКА  ложится поверх материалов
#mesh.set_material_overlay(settings.current_material)
# ложится вместо материала
#mesh.set_surface_override_material(0,settings.current_material)

# Памятка 
#await get_tree().process_frame
#await get_tree().create_timer(0.3).timeout 
#call_deferred(result)
###################################################


#DD Дебаги вкл
#@export var debug_mode := false

#const TRACK_WITH_BALLAST_HEIGHT = 0.85

### Текущий режим из : &'build' &'operate' &'observe' &'library'
#@export var current_mode :StringName = &'build' 



func _ready() -> void:
	# DebugPanel (U14) только в debug: в релизе узла нет
	if Global.debug_mode:
		_create_debug_panel()


func _create_debug_panel() -> void:
	var panel := (load("res://ui/debug/debug_panel.tscn") as PackedScene).instantiate() as DebugPanel
	$Debug.add_child(panel)
	panel.setup($ToolController, $SaveManager)


func _process(_delta: float) -> void:
	var window_title = get_window().title
	DisplayServer.window_set_title(window_title + " | fps: " +				str(Engine.get_frames_per_second()))


#
#func _exit_tree() -> void:
	##print('0')
	##await  get_tree().process_frame
	###save_game('autosave')
	##%SaveManager.save_game('autosave')
	#pass	
	
### Завершение работы
#func _notification(what):
	### Срабатывает при закрытии окна (крестик, Alt+F4)
	##if what == NOTIFICATION_WM_CLOSE_REQUEST: 
		##%SaveManager.save_game('autosave')
		##await  get_tree().process_frame
		##print('1')
		##get_tree().quit() # Разрешаем выход после сохранения
		### Непонятно зачем, но Срабатывает при штатном выходе через get_tree().quit()
	##elif what == NOTIFICATION_PREDELETE:
##
		###save_game()
		##print('2')
		###pass
	#pass
