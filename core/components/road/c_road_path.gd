class_name C_RoadPath extends C_Path

###########################
## Путь сегмента дороги (ATTN_28 §28.3)
###########################
## Тот же C_Path (get_comp(C_Path) находит и его: Entity ищет по is_instance_of), поэтому сокеты, блокировка,
## ложе рельефа и опоры видят дорогу как трак. Кривая строится как у обычного трака: прямая или дуга по radius и deg
## из паспорта RoadConfig (PathSetting.apply_passport). Отличия от рельса:
##  - сеть &"road": сокеты дороги не стыкуются с рельсом и наоборот (C_Socket.network);
##  - основание лежит на физическом слое roads, а не tracks: рельсовые траки и вагоны дорогу не видят.
## Ширина ложа рельефа (bed_half_width) и опоры эстакады приходят в CS1b и CS1c.


## Сеть из паспорта RoadConfig; без паспорта &"road"
func network_id() -> StringName:
	var idc := get_comp(C_Identity) as C_Identity
	var cfg := idc.object_config as RoadConfig if idc else null
	return cfg.network if cfg else &"road"


## Основание дороги на слое roads (Global.active_layers)
func solid_layer_bit() -> int:
	return Global.active_layers([&"roads"])
