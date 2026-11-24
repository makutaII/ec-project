class_name RideFlexConfig extends RideTrackConfig

###########################
## Паспорт гибкого трака горок (ATTN_27 §27.4, шаг C8)
###########################
## Flex горок строится тем же C_FlexShape, что и flex железной дороги, но по своим пределам формы: горки допускают
## более крутой поворот и подъём, чем рельсы. Пределы здесь, а не в GlobalSetting: у железной дороги они остаются прежними.
## length, pitch_*, roll_* унаследованы от RideTrackConfig и задают только начальную прямую до первого растяжения.

## Минимальный радиус изгиба, ю (у flex железной дороги flex_r_min = 15)
@export var flex_r_min := 8.0
## Минимальная и максимальная длина, ю
@export var flex_l_min := 4.0
@export var flex_l_max := 120.0
## Максимальный уклон (dy/ds): 0,7 это около 35° (у рельсового flex 0,045)
@export var flex_max_grade := 0.7


## C_FlexShape спрашивает пределы у паспорта; null у обычных траков значит «из GlobalSetting»
func flex_limits() -> FlexSolver.Limits:
	var lim := FlexSolver.Limits.new()
	lim.r_min = flex_r_min
	lim.l_min = flex_l_min
	lim.l_max = flex_l_max
	lim.max_grade = flex_max_grade
	return lim
