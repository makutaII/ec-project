# data/models

Модели, по одной папке на модель: `data/models/<id>/`. Вид модели читается по id (`wagon_`, `loco_`, `house_`, `room_`), отдельных подпапок по видам нет. Комнаты: `data/models/room_<имя>/room_<имя>.tscn` (карточка комнаты в `data/rooms/cards/<id>.tres`, id комнаты без префикса, например `attic` → `room_attic`).

```
data/models/wagon_04/
  wagon_04.glb (+ .import)   экспорт из Blender, имя постоянное
  wagon_04.tscn              сцена-обёртка: RigidBody3D + инстанс .glb + коллизия
  tex/                       внешние текстуры, если не вшиты в .glb
```

Правила переходного периода (см. `0_ATTN_24_model_pipeline.md` §24.12):

- Объекты каталога остаются на старых местах: `data/<категория>/objects/<id>.tres`. Каталог читает только эти папки и без рекурсии, пути записаны в сейвах.
- Паспорта остаются в `data/library/info/`.
- Старые модели (`data/import/`, `data/trains/*.tscn`, `data/buildings/*.tscn`) пока не трогаем. Переезд по одной модели в панели FileSystem Godot, отдельным коммитом; когда в старых папках ничего не останется, чистим.
- `room_test_01/room_test_01.glb`: эталон комнаты (RM7, ATTN_25 §25.7), собран `tools/room_fixture.py`; сцену-обёртку и карточку добавит RM8.
