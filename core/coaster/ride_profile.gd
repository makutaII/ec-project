class_name RideProfile extends Resource

###########################
## Профиль заезда Coaster (ATTN_27 §27.5, §27.8)
###########################
## Числа, которые подбирают по ощущению. Правятся в инспекторе (data/coaster/ride_profile.tres), без кода.
## Читает C_RideCar при создании вагона (Coaster.profile()).

@export_category("Физика")
## Коэффициент силы тяжести вдоль уклона у вагонов горок. В песочнице RailPhysics.GRADE_K = 5 (игрушечная дорога),
## здесь меньше: вагон не должен летать с каждой горки. Больше: быстрее разгон на спуске и дальше выкат
@export var grade_k: float = 2.0

@export_category("Пинок рукой (удержание ЛКМ на вагоне)")
## Удержание короче этого это обычный клик (выбор вагона), пинка нет, с, сек
@export var kick_hold_min: float = 0.25
## За сколько секунд удержания сверх kick_hold_min сила растёт от минимума до максимума
@export var kick_charge_time: float = 1.2
## Сила пинка в тех же единицах, что у PgUp и PgDn (там 10). Δv вагона массой 2 равно силе: 10 → около 10 ед/с
@export var kick_power_min: float = 3.0
@export var kick_power_max: float = 50.0
## Короткое нажатие PgUp и PgDn (быстрее kick_hold_min), без зарядки; мышью короткий клик только выбирает вагон
@export var kick_short_power: float = 2.0
