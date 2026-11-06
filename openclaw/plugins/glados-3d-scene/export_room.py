"""Run with bundled Blender -b EDIT_sp_a2_core_PACKED.blend --python export_room.py.
Only writes chamber_room.glb/report; never saves or modifies the source blend.
"""
import bpy, json, hashlib
from pathlib import Path
from mathutils import Vector
HERE = Path(__file__).resolve().parent
source = Path(bpy.data.filepath)
source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
dg = bpy.context.evaluated_depsgraph_get()
original = bpy.context.scene
# Use the top of the visible ceiling support as the attachment datum.
base = next(o for o in original.objects if "glados_disc_base_reference" in o.name)
points = [base.matrix_world @ Vector(v) for v in base.bound_box]
anchor = Vector((base.matrix_world.translation.x, base.matrix_world.translation.y, max(p.z for p in points)))
stage = bpy.data.scenes.new("Chamber export")
materials, images = {}, {}
def image_copy(image):
    if image.name not in images:
        c = image.copy()
        if max(c.size) > 1024:
            factor = 1024 / max(c.size)
            c.scale(max(1, round(c.size[0]*factor)), max(1, round(c.size[1]*factor)))
        c.file_format = 'PNG'
        images[image.name] = c
    return images[image.name]
def material_copy(mat):
    if mat.name in materials: return materials[mat.name]
    m = bpy.data.materials.new(mat.name + "_gltf")
    m.use_nodes = True
    m.diffuse_color = mat.diffuse_color
    p = m.node_tree.nodes.get("Principled BSDF")
    p.inputs['Base Color'].default_value = mat.diffuse_color
    p.inputs['Roughness'].default_value = .78
    p.inputs['Metallic'].default_value = .15 if 'metal' in mat.name else 0
    if mat.use_nodes:
        nodes = mat.node_tree.nodes
        base_node = next((n for n in nodes if n.type == 'TEX_IMAGE' and n.image and n.name.lower() == '$basetexture'), None)
        if base_node is None:
            base_node = next((n for n in nodes if n.type == 'TEX_IMAGE' and n.image and not any(s in n.name.lower() for s in ['bump','normal','mask'])), None)
        for source_node, socket in [(base_node, 'Base Color'), (next((n for n in nodes if n.type=='TEX_IMAGE' and n.image and n.name.lower()=='$bumpmap'), None), 'Normal')]:
            if source_node:
                t = m.node_tree.nodes.new('ShaderNodeTexImage')
                t.image = image_copy(source_node.image)
                t.extension = source_node.extension
                if socket == 'Normal':
                    t.image.colorspace_settings.name = 'Non-Color'
                    normal = m.node_tree.nodes.new('ShaderNodeNormalMap')
                    m.node_tree.links.new(t.outputs['Color'], normal.inputs['Color'])
                    m.node_tree.links.new(normal.outputs['Normal'], p.inputs['Normal'])
                else:
                    m.node_tree.links.new(t.outputs['Color'], p.inputs[socket])
                    if any(s in mat.name.lower() for s in ['light','emissive']) and 'lightmap' not in mat.name.lower():
                        m.node_tree.links.new(t.outputs['Color'], p.inputs['Emission Color'])
                        p.inputs['Emission Strength'].default_value = .35
    materials[mat.name] = m
    return m
count = 0
excluded = []
for o in list(original.objects):
    if o.type != 'MESH' or not o.visible_get() or o.hide_render: continue
    # Hidden character variants are not part of the room; keep only architecture/props.
    if '/npcs/glados/' in o.name or 'glados_head.mdl' in o.name or 'glados_disc_base_reference' in o.name: continue
    e = o.evaluated_get(dg)
    mesh = bpy.data.meshes.new_from_object(e, preserve_all_data_layers=True, depsgraph=dg)
    if not mesh.polygons: continue
    # Source tool/nodraw faces are non-rendered engine geometry.
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(mesh)
    remove = [f for f in bm.faces if f.material_index < len(mesh.materials) and mesh.materials[f.material_index] and mesh.materials[f.material_index].name.startswith('tools/')]
    bmesh.ops.delete(bm, geom=remove, context='FACES')
    bm.to_mesh(mesh)
    bm.free()
    if not mesh.polygons: continue
    for i, m in enumerate(mesh.materials):
        if m: mesh.materials[i] = material_copy(m)
    # Source vertex colors encode engine lighting, not glTF base color.
    for attr in list(mesh.color_attributes): mesh.color_attributes.remove(attr)
    obj = bpy.data.objects.new(o.name, mesh)
    stage.collection.objects.link(obj)
    obj.matrix_world = e.matrix_world.copy()
    obj.location -= anchor
    count += 1
bpy.context.window.scene = stage
bpy.ops.object.select_all(action='SELECT')
bpy.context.view_layer.objects.active = next(iter(stage.objects))
bpy.ops.object.join()
bpy.context.object.data.validate(clean_customdata=False)
bpy.context.object.data.update()
# Merge static meshes; glTF emits a primitive per material rather than 1,000+ draw calls.
bpy.ops.export_scene.gltf(filepath=str(HERE/'models'/'chamber_room.glb'), export_format='GLB',
    export_animations=False, export_skins=False, export_cameras=False, export_lights=False,
    export_yup=True, export_apply=True, export_image_format='JPEG', export_jpeg_quality=85, export_extras=False, use_active_scene=True)
report = dict(source=str(source), sourceSHA256=source_hash, sourceUnchanged=hashlib.sha256(source.read_bytes()).hexdigest()==source_hash,
    sourceMeshes=count, materials=len(materials), images=len(images), blenderAnchor=list(anchor),
    attachment='glados_disc_base_reference top; exported origin; support omitted to retain existing rig', bytes=(HERE/'models'/'chamber_room.glb').stat().st_size)
(HERE/'room-export.json').write_text(json.dumps(report,indent=2))
print('ROOM_EXPORT',json.dumps(report))
