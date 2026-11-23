bl_info = {
    "name": "Hierarchy Extractor & Parent Assigner",
    "author": "AI Assistant",
    "version": (2, 0),
    "blender": (3, 0, 0),
    "location": "View3D > N-Panel > Extract",
    "description": "Вытаскивает меши, назначает главный меш со свойством room/body и удаляет пустышки",
    "category": "Object",
}

import bpy

def get_all_children(obj):
    children = []
    for child in obj.children:
        children.append(child)
        children.extend(get_all_children(child))
    return children

def get_collections(self, context):
    items = [("SCENE_ROOT", "Scene Collection (Корень)", "Переместить в корень сцены")]
    for col in bpy.data.collections:
        items.append((col.name, col.name, f"Переместить в {col.name}"))
    return items

class OBJECT_OT_extract_and_parent(bpy.types.Operator):
    bl_idname = "object.extract_and_parent"
    bl_label = "Извлечь и привязать"
    bl_options = {'REGISTER', 'UNDO'}

    def execute(self, context):
        scene = context.scene
        selected = context.selected_objects
        active = context.active_object

        if not selected:
            self.report({'WARNING'}, "Ничего не выделено!")
            return {'CANCELLED'}

        # Собираем всю иерархию из выделенных объектов
        all_objects = set(selected)
        for obj in selected:
            all_objects.update(get_all_children(obj))

        # Разделяем меши и пустышки
        meshes = [obj for obj in all_objects if obj.type == 'MESH']
        empties = [obj for obj in all_objects if obj.type == 'EMPTY']

        if not meshes:
            self.report({'WARNING'}, "В выделенной иерархии не найдено ни одного меша!")
            return {'CANCELLED'}

        # Определяем главный родительский меш
        # Если активный объект — один из найденных мешей, берём его. Иначе — первый попавшийся меш
        if active and active in meshes:
            main_mesh = active
        else:
            main_mesh = meshes[0]

        # Определяем целевую коллекцию
        target_col_name = scene.ext_target_collection
        if target_col_name == "SCENE_ROOT":
            dest_col = scene.collection
        else:
            dest_col = bpy.data.collections.get(target_col_name, scene.collection)

        # 1. Настраиваем главный родительский меш
        main_world_matrix = main_mesh.matrix_world.copy()
        main_mesh.parent = None
        main_mesh.matrix_world = main_world_matrix
        
        # Записываем Custom Property (тип: room или body)
        main_mesh["type"] = scene.ext_prop_type

        for col in list(main_mesh.users_collection):
            col.objects.unlink(main_mesh)
        if main_mesh.name not in dest_col.objects:
            dest_col.objects.link(main_mesh)

        # 2. Обрабатываем остальные меши и привязываем их к главному мешу
        child_meshes_count = 0
        for mesh in meshes:
            if mesh == main_mesh:
                continue

            world_matrix = mesh.matrix_world.copy()
            mesh.parent = main_mesh
            mesh.matrix_parent_inverse = main_mesh.matrix_world.inverted()
            mesh.matrix_world = world_matrix

            for col in list(mesh.users_collection):
                col.objects.unlink(mesh)
            if mesh.name not in dest_col.objects:
                dest_col.objects.link(mesh)

            child_meshes_count += 1

        # 3. Удаляем опустевшие пустышки (снизу вверх)
        empties_deleted = 0
        empties.sort(key=lambda o: len(get_all_children(o)))
        for emp in empties:
            if len(emp.children) == 0:
                bpy.data.objects.remove(emp, do_unlink=True)
                empties_deleted += 1

        self.report(
            {'INFO'}, 
            f"Главный: '{main_mesh.name}' ({scene.ext_prop_type}) | Детей: {child_meshes_count} | Удалено пустышек: {empties_deleted}"
        )
        return {'FINISHED'}


class VIEW3D_PT_extract_panel(bpy.types.Panel):
    bl_label = "Hierarchy Extractor"
    bl_idname = "VIEW3D_PT_extract_panel"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = 'Extract'  # Название вкладки в N-панели

    def draw(self, context):
        layout = self.layout
        scene = context.scene

        # Выбор целевой коллекции
        layout.label(text="Куда перенести:")
        layout.prop(scene, "ext_target_collection", text="")

        layout.separator()

        # Выбор кастом проперти (room / body)
        layout.label(text="Свойство главного меша:")
        row = layout.row(align=True)
        row.prop(scene, "ext_prop_type", expand=True)

        layout.separator()

        # Подсказка, какой меш станет главным
        active = context.active_object
        if active and active.type == 'MESH':
            layout.label(text=f"Главный: {active.name}", icon='MESH_DATA')
        else:
            layout.label(text="Главный: первый найденный", icon='INFO')

        # Кнопка запуска
        layout.operator("object.extract_and_parent", icon='OUTLINER_OB_MESH')


def register():
    bpy.types.Scene.ext_target_collection = bpy.props.EnumProperty(
        name="Коллекция",
        description="Выберите куда перенести меши",
        items=get_collections
    )
    bpy.types.Scene.ext_prop_type = bpy.props.EnumProperty(
        name="Тип",
        description="Значение кастомного свойства для главного меша",
        items=[
            ('room', "Room", "Назначить свойство room"),
            ('body', "Body", "Назначить свойство body"),
        ],
        default='room'
    )
    bpy.utils.register_class(OBJECT_OT_extract_and_parent)
    bpy.utils.register_class(VIEW3D_PT_extract_panel)


def unregister():
    del bpy.types.Scene.ext_target_collection
    del bpy.types.Scene.ext_prop_type
    bpy.utils.unregister_class(OBJECT_OT_extract_and_parent)
    bpy.utils.unregister_class(VIEW3D_PT_extract_panel)


if __name__ == "__main__":
    register()
