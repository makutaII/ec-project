class_name Coaster extends RefCounted

###########################
## 🎢 Coaster. Константы режима «горки» (ATTN_27)
###########################
## Дорога без электроприводов: деревянные лотки, вагоны катятся по инерции.
## Весь код режима живёт в core/coaster/, данные в data/coaster/ (правило выноса, ATTN_27 §27.10).
## Общие файлы проекта знают о режиме только по строкам-ключам (режим, категории, папка объектов) и
## помечены «XX claude-coaster»: список этих мест это то, что надо будет унести или заменить при выносе.
## Эти константы нужны коду самого Coaster, общие файлы их не используют.

## Режим игры (Global.current_mode, кнопка «CoasterButton» в TopBar)
const MODE := &"coaster"
## Категории каталога режима
const CAT_TRACK := &"coaster_track"
const CAT_CAR := &"coaster_car"   # вагоны появятся в шаге C3
## Папка объектов (входит в Global.object_dirs)
const OBJECTS_DIR := "res://data/coaster/objects/"


## Сейчас включён режим Coaster
static func is_active() -> bool:
	return Global.current_mode == MODE
