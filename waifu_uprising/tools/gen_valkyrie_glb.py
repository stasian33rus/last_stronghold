#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Генератор игровых 3D-моделей Валькирии (Waifu Uprising, Этап 3.2).
Запуск:  blender --background --python tools/gen_valkyrie_glb.py -- <outdir>
Создаёт ТРИ настоящих glTF Binary (.glb): valkyrie_f1.glb, valkyrie_f2.glb,
valkyrie_f3.glb — стилизованные взрослые fantasy-аниме героини (аниме-вайфу),
без наготы: лёгкая броня закрытого кроя (нагрудник/юбка-фолд/поножи/сапоги).

Общий скелет (одинаковые имена/иерархия костей у всех форм — совместимые
анимации): Hips → Spine → Chest → {Head, Shoulder.L/R → UpperArm → LowerArm →
Hand → Weapon}, Thigh → Shin → Foot, Wing1 → Wing2, плюс Weapon.L у обеих рук.

Анимации (8, общие по таймингу): idle, run, attack, skill, parry, hit, death,
transform. Оружие/крылья/сменные элементы брони — отдельные объекты, жёстко
привязанные к своим костям (vertex group + Armature modifier, вес 1.0).
Материалы — PBR metallic/roughness. Форма III: багрово-золотая палитра,
усиленные крылья, плащ-накидка, узел "Aura" (красное эмиссивное кольцо +
кристаллы; вращается кодом visuals в Godot — локальная косметика).

Полигональный бюджет: умеренный (~4-6k треугольников на форму).
Скрипт печатает фактическую статистику (треугольники/объекты/анимации) —
эти числа идут в отчёт этапа.
"""
import bpy
import bmesh
import math
import os
import sys

FPS = 30
OUT_DIR = "/tmp/valkyrie_out"
argv = sys.argv
if "--" in argv:
    args = argv[argv.index("--") + 1:]
    if args:
        OUT_DIR = args[0]
os.makedirs(OUT_DIR, exist_ok=True)

D = math.degrees
R = math.radians


# ---------------------------------------------------------------- материалы
def make_material(name, color, metallic=0.0, roughness=0.5,
                  emission=None, emission_strength=0.0, alpha=1.0):
    m = bpy.data.materials.get(name)
    if m is None:
        m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    if emission is not None:
        bsdf.inputs["Emission Color"].default_value = (*emission, 1.0)
        bsdf.inputs["Emission Strength"].default_value = emission_strength
    if alpha < 1.0:
        try:
            bsdf.inputs["Alpha"].default_value = alpha
        except Exception:
            pass
        try:
            m.blend_method = "BLEND"
        except Exception:
            pass
    return m


# ---------------------------------------------------------------- геометрия
def _bm_to_mesh_obj(name, bm, material, coll):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    obj.data.materials.append(material)
    coll.objects.link(obj)
    return obj


def box(name, sx, sy, sz, loc, rot=(0, 0, 0), mat=None, coll=None, taper=1.0):
    """Куб (12 треуг.), taper — сужение верхней грани (силуэт)."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co.x *= sx
        v.co.y *= sy
        v.co.z *= sz
        if v.co.z > 0 and taper != 1.0:
            v.co.x *= taper
            v.co.y *= taper
    _rotate(bm, rot)
    _move(bm, loc)
    return _bm_to_mesh_obj(name, bm, mat, coll)


def sphere(name, r, loc, rot=(0, 0, 0), mat=None, coll=None,
           sx=1.0, sy=1.0, sz=1.0, seg=16, rings=10):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=r)
    for v in bm.verts:
        v.co.x *= sx
        v.co.y *= sy
        v.co.z *= sz
    _rotate(bm, rot)
    _move(bm, loc)
    return _bm_to_mesh_obj(name, bm, mat, coll)


def cyl(name, r1, r2, h, loc, rot=(0, 0, 0), mat=None, coll=None, seg=12):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=True, segments=seg,
                          radius1=r1, radius2=r2, depth=h)
    _rotate(bm, rot)
    _move(bm, loc)
    return _bm_to_mesh_obj(name, bm, mat, coll)


def torus(name, rmajor, rminor, loc, rot=(0, 0, 0), mat=None, coll=None,
          majseg=16, minseg=8):
    """Тор вручную (bmesh.ops.create_torus в 4.5 не существует)."""
    bm = bmesh.new()
    grid = []
    for i in range(majseg):
        a = 2.0 * math.pi * i / majseg
        ring = []
        for j in range(minseg):
            b = 2.0 * math.pi * j / minseg
            r = rmajor + rminor * math.cos(b)
            ring.append(bm.verts.new((r * math.cos(a), r * math.sin(a),
                                      rminor * math.sin(b))))
        grid.append(ring)
    for i in range(majseg):
        for j in range(minseg):
            v1 = grid[i][j]
            v2 = grid[(i + 1) % majseg][j]
            v3 = grid[(i + 1) % majseg][(j + 1) % minseg]
            v4 = grid[i][(j + 1) % minseg]
            bm.faces.new((v1, v2, v3, v4))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    _rotate(bm, rot)
    _move(bm, loc)
    return _bm_to_mesh_obj(name, bm, mat, coll)


def octa(name, w, h, loc, rot=(0, 0, 0), mat=None, coll=None):
    """Октаэдр-кристалл (8 треуг.)."""
    verts = [(0, 0, h), (w, 0, 0), (-w, 0, 0), (0, w, 0), (0, -w, 0), (0, 0, -h * 0.7)]
    faces = [(0, 1, 3), (0, 3, 2), (0, 2, 4), (0, 4, 1),
             (5, 3, 1), (5, 2, 3), (5, 4, 2), (5, 1, 4)]
    bm = bmesh.new()
    vs = [bm.verts.new(v) for v in verts]
    for f in faces:
        bm.faces.new([vs[i] for i in f])
    _rotate(bm, rot)
    _move(bm, loc)
    return _bm_to_mesh_obj(name, bm, mat, coll)


def _rotate(bm, rot):
    if rot == (0, 0, 0):
        return
    from mathutils import Matrix
    m = (Matrix.Rotation(R(rot[2]), 4, "Z")
         @ Matrix.Rotation(R(rot[1]), 4, "Y")
         @ Matrix.Rotation(R(rot[0]), 4, "X"))
    bmesh.ops.rotate(bm, matrix=m, verts=bm.verts[:])


def _move(bm, loc):
    from mathutils import Vector
    bmesh.ops.translate(bm, vec=Vector(loc), verts=bm.verts[:])


# ---------------------------------------------------------------- скелет
BONES = [
    # (имя, родитель, head, tail)
    ("Hips", None, (0, 0, 0.95), (0, 0, 1.10)),
    ("Spine", "Hips", (0, 0, 1.10), (0, 0, 1.30)),
    ("Chest", "Spine", (0, 0, 1.30), (0, 0, 1.48)),
    ("Head", "Chest", (0, 0, 1.48), (0, 0, 1.62)),
    ("Shoulder.L", "Chest", (0.05, 0, 1.44), (0.19, 0, 1.45)),
    ("Shoulder.R", "Chest", (-0.05, 0, 1.44), (-0.19, 0, 1.45)),
    ("UpperArm.L", "Shoulder.L", (0.19, 0, 1.44), (0.215, 0.01, 1.16)),
    ("UpperArm.R", "Shoulder.R", (-0.19, 0, 1.44), (-0.215, 0.01, 1.16)),
    ("LowerArm.L", "UpperArm.L", (0.215, 0.01, 1.16), (0.225, 0.03, 0.90)),
    ("LowerArm.R", "UpperArm.R", (-0.215, 0.01, 1.16), (-0.225, 0.03, 0.90)),
    ("Hand.L", "LowerArm.L", (0.225, 0.03, 0.90), (0.23, 0.04, 0.80)),
    ("Hand.R", "LowerArm.R", (-0.225, 0.03, 0.90), (-0.23, 0.04, 0.80)),
    ("Weapon", "Hand.R", (-0.23, 0.04, 0.80), (-0.23, 0.04, 0.62)),
    ("Weapon.L", "Hand.L", (0.23, 0.04, 0.80), (0.23, 0.04, 0.62)),
    ("Thigh.L", "Hips", (0.10, 0, 0.93), (0.105, 0.01, 0.53)),
    ("Thigh.R", "Hips", (-0.10, 0, 0.93), (-0.105, 0.01, 0.53)),
    ("Shin.L", "Thigh.L", (0.105, 0.01, 0.53), (0.105, 0.02, 0.13)),
    ("Shin.R", "Thigh.R", (-0.105, 0.01, 0.53), (-0.105, 0.02, 0.13)),
    ("Foot.L", "Shin.L", (0.105, 0.02, 0.13), (0.105, -0.11, 0.05)),
    ("Foot.R", "Shin.R", (-0.105, 0.02, 0.13), (-0.105, -0.11, 0.05)),
    ("Wing1.L", "Chest", (0.10, 0.09, 1.40), (0.34, 0.30, 1.74)),
    ("Wing1.R", "Chest", (-0.10, 0.09, 1.40), (-0.34, 0.30, 1.74)),
    ("Wing2.L", "Wing1.L", (0.34, 0.30, 1.74), (0.62, 0.52, 2.00)),
    ("Wing2.R", "Wing1.R", (-0.34, 0.30, 1.74), (-0.62, 0.52, 2.00)),
]


def build_armature(coll):
    arm_data = bpy.data.armatures.new("ValkyrieArmature")
    arm_obj = bpy.data.objects.new("Armature", arm_data)
    coll.objects.link(arm_obj)
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode="EDIT")
    ebs = {}
    for name, parent, head, tail in BONES:
        eb = arm_data.edit_bones.new(name)
        eb.head = head
        eb.tail = tail
        ebs[name] = eb
    for name, parent, head, tail in BONES:
        if parent:
            ebs[name].parent = ebs[parent]
            ebs[name].use_connect = False
    bpy.ops.object.mode_set(mode="OBJECT")
    if arm_obj.animation_data is None:
        arm_obj.animation_data_create()
    return arm_obj


def bind(obj, arm_obj, bone):
    """Жёсткая привязка части к кости (вес 1.0) — простая и надёжная skin-схема."""
    obj.parent = arm_obj
    vg = obj.vertex_groups.new(name=bone)
    vg.add(range(len(obj.data.vertices)), 1.0, "REPLACE")
    mod = obj.modifiers.new(name="Armature", type="ARMATURE")
    mod.object = arm_obj


# ---------------------------------------------------------------- анимации
def _pb(arm, name):
    pb = arm.pose.bones[name]
    pb.rotation_mode = "XYZ"
    return pb


def _key_rot(arm, name, frame, rx=0, ry=0, rz=0):
    pb = _pb(arm, name)
    pb.rotation_euler = (R(rx), R(ry), R(rz))
    pb.keyframe_insert("rotation_euler", frame=frame)


def _key_loc(arm, name, frame, dx=0, dy=0, dz=0):
    pb = _pb(arm, name)
    pb.location = (dx, dy, dz)
    pb.keyframe_insert("location", frame=frame)


def _new_action(arm, name):
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    arm.animation_data.action = act
    return act


def anim_idle(arm):
    a = _new_action(arm, "idle")
    for f, br, wz, w2 in [(1, 0, 0, 0), (18, -2.0, 5.0, 8.0), (36, 0, 0, 0),
                          (54, -2.0, 5.0, 8.0), (72, 0, 0, 0)]:
        _key_rot(arm, "Chest", f, rx=br)
        _key_loc(arm, "Hips", f, dz=0.008 * math.sin(2 * math.pi * (f - 1) / 71.0))
        _key_rot(arm, "Wing1.L", f, rz=-wz)
        _key_rot(arm, "Wing1.R", f, rz=wz)
        _key_rot(arm, "Wing2.L", f, rz=-w2)
        _key_rot(arm, "Wing2.R", f, rz=w2)
        _key_rot(arm, "Head", f, ry=1.5 * math.sin(2 * math.pi * (f - 1) / 71.0))
        _key_rot(arm, "UpperArm.L", f, rz=-4 + 2 * math.sin(2 * math.pi * (f - 1) / 71.0))
        _key_rot(arm, "UpperArm.R", f, rz=4 - 2 * math.sin(2 * math.pi * (f - 1) / 71.0))
    return a


def anim_run(arm):
    a = _new_action(arm, "run")
    # цикл 0.66 c (20 кадров), ноги в противофазе
    ph = [(1, 1.0), (6, 0.0), (11, -1.0), (16, 0.0), (20, 1.0)]
    for f, s in ph:
        amp = 34 * s
        _key_rot(arm, "Thigh.L", f, rx=-amp)
        _key_rot(arm, "Thigh.R", f, rx=amp)
        _key_rot(arm, "Shin.L", f, rx=max(0.0, amp) * 0.9 + 6)
        _key_rot(arm, "Shin.R", f, rx=max(0.0, -amp) * 0.9 + 6)
        _key_rot(arm, "UpperArm.L", f, rx=amp * 0.6)
        _key_rot(arm, "UpperArm.R", f, rx=-amp * 0.6)
        _key_rot(arm, "LowerArm.L", f, rx=-14)
        _key_rot(arm, "LowerArm.R", f, rx=-14)
        _key_loc(arm, "Hips", f, dz=-0.02 * abs(s) + 0.02)
    for f in (1, 20):
        _key_rot(arm, "Chest", f, rx=8)
        _key_rot(arm, "Wing1.L", f, rx=18, rz=-8)
        _key_rot(arm, "Wing1.R", f, rx=18, rz=8)
        _key_rot(arm, "Wing2.L", f, rz=-12)
        _key_rot(arm, "Wing2.R", f, rz=12)
    return a


def anim_attack(arm):
    a = _new_action(arm, "attack")
    _key_rot(arm, "UpperArm.R", 1, rx=0, rz=6)
    _key_rot(arm, "Chest", 1, ry=0)
    _key_rot(arm, "UpperArm.R", 4, rx=-95, rz=14)   # замах (windup ~0.10 c)
    _key_rot(arm, "Chest", 4, ry=-22)
    _key_rot(arm, "UpperArm.R", 7, rx=62, rz=-6)    # удар (окно ~0.10 c)
    _key_rot(arm, "Chest", 7, ry=26)
    _key_rot(arm, "LowerArm.R", 7, rx=-16)
    _key_rot(arm, "UpperArm.R", 11, rx=26, rz=2)
    _key_rot(arm, "Chest", 11, ry=8)
    _key_rot(arm, "UpperArm.R", 16, rx=0, rz=6)     # возврат
    _key_rot(arm, "Chest", 16, ry=0)
    _key_rot(arm, "LowerArm.R", 16, rx=0)
    return a


def anim_skill(arm):
    a = _new_action(arm, "skill")
    _key_loc(arm, "Hips", 1, dz=0)
    _key_loc(arm, "Hips", 3, dz=-0.07)
    _key_rot(arm, "Thigh.L", 3, rx=-16)
    _key_rot(arm, "Thigh.R", 3, rx=-16)
    _key_rot(arm, "Chest", 3, rx=10)
    _key_rot(arm, "UpperArm.R", 3, rx=-70, rz=26)   # оружие горизонтально
    _key_loc(arm, "Hips", 4, dz=-0.05)
    for f, ang in [(4, 0), (7, 90), (10, 180), (13, 270), (16, 360)]:
        _key_rot(arm, "Hips", f, ry=ang)
    _key_rot(arm, "UpperArm.R", 16, rx=-70, rz=26)
    _key_rot(arm, "Chest", 16, rx=6)
    _key_loc(arm, "Hips", 18, dz=0)
    _key_rot(arm, "Hips", 18, ry=360)
    _key_rot(arm, "UpperArm.R", 18, rx=0, rz=6)
    _key_rot(arm, "Chest", 18, rx=0)
    _key_rot(arm, "Thigh.L", 18, rx=0)
    _key_rot(arm, "Thigh.R", 18, rx=0)
    return a


def anim_parry(arm):
    a = _new_action(arm, "parry")
    for f in (1, 3):
        _key_rot(arm, "UpperArm.R", f, rx=-64, rz=18)
        _key_rot(arm, "LowerArm.R", f, rx=-46)
        _key_rot(arm, "UpperArm.L", f, rx=-58, rz=-18)
        _key_rot(arm, "LowerArm.L", f, rx=-46)
        _key_rot(arm, "Chest", f, rx=8)
        _key_loc(arm, "Hips", f, dz=-0.045)
        _key_rot(arm, "Thigh.L", f, rx=-12)
        _key_rot(arm, "Thigh.R", f, rx=-12)
        _key_rot(arm, "Shin.L", f, rx=16)
        _key_rot(arm, "Shin.R", f, rx=16)
    for f in (11, 15):
        _key_rot(arm, "UpperArm.R", f, rx=0, rz=6)
        _key_rot(arm, "LowerArm.R", f, rx=0)
        _key_rot(arm, "UpperArm.L", f, rx=0, rz=-6)
        _key_rot(arm, "LowerArm.L", f, rx=0)
        _key_rot(arm, "Chest", f, rx=0)
        _key_loc(arm, "Hips", f, dz=0)
        _key_rot(arm, "Thigh.L", f, rx=0)
        _key_rot(arm, "Thigh.R", f, rx=0)
        _key_rot(arm, "Shin.L", f, rx=0)
        _key_rot(arm, "Shin.R", f, rx=0)
    _key_rot(arm, "UpperArm.R", 7, rx=-64, rz=18)
    _key_rot(arm, "UpperArm.L", 7, rx=-58, rz=-18)
    return a


def anim_hit(arm):
    a = _new_action(arm, "hit")
    _key_rot(arm, "Chest", 1, rx=0)
    _key_rot(arm, "Chest", 3, rx=16)
    _key_rot(arm, "Head", 3, rx=14)
    _key_rot(arm, "UpperArm.L", 3, rx=26, rz=-18)
    _key_rot(arm, "UpperArm.R", 3, rx=26, rz=18)
    _key_loc(arm, "Hips", 3, dy=0.03)
    for f in (9,):
        _key_rot(arm, "Chest", f, rx=0)
        _key_rot(arm, "Head", f, rx=0)
        _key_rot(arm, "UpperArm.L", f, rx=0, rz=-4)
        _key_rot(arm, "UpperArm.R", f, rx=0, rz=4)
        _key_loc(arm, "Hips", f, dy=0)
    return a


def anim_death(arm):
    a = _new_action(arm, "death")
    _key_rot(arm, "Chest", 1, rx=0)
    _key_loc(arm, "Hips", 1, dz=0)
    _key_rot(arm, "Hips", 1, rx=0)
    _key_rot(arm, "Chest", 6, rx=14)
    _key_rot(arm, "UpperArm.L", 6, rx=40, rz=-30)
    _key_rot(arm, "UpperArm.R", 6, rx=40, rz=30)
    _key_rot(arm, "Hips", 16, rx=78)
    _key_loc(arm, "Hips", 16, dz=-0.62, dy=0.10)
    _key_rot(arm, "Chest", 16, rx=16)
    _key_rot(arm, "Head", 16, rx=18)
    _key_rot(arm, "Thigh.L", 16, rx=-34)
    _key_rot(arm, "Thigh.R", 16, rx=-24)
    _key_rot(arm, "Shin.L", 16, rx=34)
    _key_rot(arm, "Shin.R", 16, rx=26)
    _key_rot(arm, "UpperArm.L", 16, rx=8, rz=-74)
    _key_rot(arm, "UpperArm.R", 16, rx=8, rz=74)
    _key_rot(arm, "Wing1.L", 16, rx=-30, rz=-14)
    _key_rot(arm, "Wing1.R", 16, rx=-30, rz=14)
    _key_rot(arm, "Hips", 22, rx=78)
    _key_loc(arm, "Hips", 22, dz=-0.66, dy=0.12)
    return a


def anim_transform(arm):
    a = _new_action(arm, "transform")
    _key_loc(arm, "Hips", 1, dz=0)
    _key_loc(arm, "Hips", 6, dz=-0.10)
    _key_rot(arm, "Thigh.L", 6, rx=-26)
    _key_rot(arm, "Thigh.R", 6, rx=-26)
    _key_rot(arm, "Shin.L", 6, rx=30)
    _key_rot(arm, "Shin.R", 6, rx=30)
    _key_rot(arm, "Chest", 6, rx=12)
    _key_loc(arm, "Hips", 14, dz=0.03)
    _key_rot(arm, "UpperArm.L", 14, rz=-118)
    _key_rot(arm, "UpperArm.R", 14, rz=118)
    _key_rot(arm, "Chest", 14, rx=-8)
    _key_rot(arm, "Head", 14, rx=-16)
    _key_rot(arm, "Wing1.L", 14, rx=-26, rz=-52)
    _key_rot(arm, "Wing1.R", 14, rx=-26, rz=52)
    _key_rot(arm, "Wing2.L", 14, rz=-38)
    _key_rot(arm, "Wing2.R", 14, rz=38)
    _key_loc(arm, "Hips", 20, dz=0.0)
    _key_rot(arm, "Thigh.L", 20, rx=0)
    _key_rot(arm, "Thigh.R", 20, rx=0)
    _key_rot(arm, "Shin.L", 20, rx=0)
    _key_rot(arm, "Shin.R", 20, rx=0)
    _key_rot(arm, "UpperArm.L", 28, rz=-8)
    _key_rot(arm, "UpperArm.R", 28, rz=8)
    _key_rot(arm, "Chest", 28, rx=0)
    _key_rot(arm, "Head", 28, rx=0)
    _key_rot(arm, "Wing1.L", 28, rx=0, rz=-4)
    _key_rot(arm, "Wing1.R", 28, rx=0, rz=4)
    _key_rot(arm, "Wing2.L", 28, rz=0)
    _key_rot(arm, "Wing2.R", 28, rz=0)
    return a


ANIMS = [anim_idle, anim_run, anim_attack, anim_skill,
         anim_parry, anim_hit, anim_death, anim_transform]


# ---------------------------------------------------------------- формы
FORMS = {
    "valkyrie_f1": dict(
        file="valkyrie_f1.glb", label="Форма I «Валькирия»",
        armor=(0.90, 0.91, 0.95), armor_metal=0.35, armor_rough=0.35,
        trim=(0.85, 0.68, 0.25), trim_metal=0.9, trim_rough=0.25,
        suit=(0.26, 0.28, 0.40), skin=(1.0, 0.86, 0.76),
        hair=(0.82, 0.85, 0.93), hair_metal=0.25, hair_rough=0.38,
        feather=(0.95, 0.96, 1.0), feather_em=None,
        steel=(0.76, 0.79, 0.86), cape=None, aura=None,
        weapon="spear", wingscale=1.12, crown="none", braids=False,
        glow_trim=0.35, wings=True, horns=False, bulk=1.0,
        out="valkyrie/valkyrie_f1.glb",
    ),
    "valkyrie_f2": dict(
        file="valkyrie_f2.glb", label="Форма II «Клинковый танец»",
        armor=(0.72, 0.80, 0.99), armor_metal=0.45, armor_rough=0.30,
        trim=(0.95, 0.78, 0.30), trim_metal=0.95, trim_rough=0.20,
        suit=(0.20, 0.24, 0.44), skin=(1.0, 0.86, 0.76),
        hair=(0.80, 0.84, 0.95), hair_metal=0.25, hair_rough=0.36,
        feather=(0.92, 0.94, 1.0), feather_em=(0.35, 0.45, 0.9),
        steel=(0.80, 0.83, 0.90), cape=None, aura=None,
        weapon="dual", wingscale=1.2, crown="circlet", braids=True,
        glow_trim=0.8, wings=True, horns=False, bulk=1.0,
        out="valkyrie/valkyrie_f2.glb",
    ),
    "valkyrie_f3": dict(
        file="valkyrie_f3.glb", label="Форма III «Багровая богиня»",
        armor=(0.66, 0.09, 0.17), armor_metal=0.5, armor_rough=0.28,
        trim=(1.0, 0.80, 0.32), trim_metal=0.95, trim_rough=0.18,
        suit=(0.20, 0.08, 0.12), skin=(1.0, 0.86, 0.76),
        hair=(0.90, 0.90, 0.96), hair_metal=0.3, hair_rough=0.32,
        feather=(0.72, 0.10, 0.20), feather_em=(0.9, 0.12, 0.2),
        steel=(0.85, 0.70, 0.55), cape=(0.55, 0.06, 0.14), aura=(1.0, 0.16, 0.22),
        weapon="dual", wingscale=1.4, crown="crown", braids=False,
        glow_trim=1.7, wings=True, horns=False, bulk=1.0,
        out="valkyrie/valkyrie_f3.glb",
    ),
    # ---------------- Берсерк (канон §6.6): массивный силуэт, огромный молот ----------------
    "berserk_f1": dict(
        file="berserk_f1.glb", label="Берсерка, форма I",
        armor=(0.72, 0.12, 0.30), armor_metal=0.4, armor_rough=0.4,
        trim=(0.95, 0.75, 0.3), trim_metal=0.9, trim_rough=0.25,
        suit=(0.18, 0.12, 0.16), skin=(1.0, 0.86, 0.76),
        hair=(0.95, 0.2, 0.45), hair_metal=0.2, hair_rough=0.4,
        feather=(1, 1, 1), feather_em=None,
        steel=(0.55, 0.56, 0.62), cape=None, aura=None,
        weapon="hammer", wingscale=1.0, crown="none", braids=False,
        glow_trim=0.3, wings=False, horns=True, bulk=1.18,
        out="berserk/berserk_f1.glb",
    ),
    "berserk_f2": dict(
        file="berserk_f2.glb", label="Берсерка, форма II «Волна ярости»",
        armor=(0.62, 0.08, 0.22), armor_metal=0.5, armor_rough=0.35,
        trim=(1.0, 0.8, 0.3), trim_metal=0.95, trim_rough=0.2,
        suit=(0.16, 0.10, 0.14), skin=(1.0, 0.86, 0.76),
        hair=(0.98, 0.25, 0.5), hair_metal=0.25, hair_rough=0.36,
        feather=(1, 1, 1), feather_em=None,
        steel=(0.6, 0.58, 0.64), cape=None, aura=None,
        weapon="hammer", wingscale=1.0, crown="none", braids=False,
        glow_trim=0.9, wings=False, horns=True, bulk=1.24,
        out="berserk/berserk_f2.glb",
    ),
    "berserk_f3": dict(
        file="berserk_f3.glb", label="Берсерка, форма III «Абсолютная ярость»",
        armor=(0.5, 0.05, 0.12), armor_metal=0.55, armor_rough=0.3,
        trim=(1.0, 0.72, 0.25), trim_metal=0.95, trim_rough=0.18,
        suit=(0.14, 0.08, 0.10), skin=(1.0, 0.86, 0.76),
        hair=(1.0, 0.3, 0.55), hair_metal=0.3, hair_rough=0.32,
        feather=(1, 1, 1), feather_em=None,
        steel=(0.65, 0.5, 0.45), cape=(0.4, 0.04, 0.1), aura=(1.0, 0.35, 0.12),
        weapon="hammer", wingscale=1.0, crown="crown", braids=False,
        glow_trim=1.6, wings=False, horns=True, bulk=1.3,
        out="berserk/berserk_f3.glb",
    ),
}


def build_form(key, cfg):
    coll = bpy.data.collections.new(key)
    bpy.context.scene.collection.children.link(coll)
    arm = build_armature(coll)

    armor = make_material(key + "_armor", cfg["armor"], cfg["armor_metal"], cfg["armor_rough"],
                          emission=(cfg["trim"] if cfg["glow_trim"] else None),
                          emission_strength=cfg["glow_trim"] * 0.25 if cfg["glow_trim"] else 0.0)
    trim = make_material(key + "_trim", cfg["trim"], cfg["trim_metal"], cfg["trim_rough"],
                         emission=cfg["trim"], emission_strength=cfg["glow_trim"])
    suit = make_material(key + "_suit", cfg["suit"], 0.0, 0.72)
    skin = make_material(key + "_skin", cfg["skin"], 0.0, 0.62)
    hair = make_material(key + "_hair", cfg["hair"], cfg["hair_metal"], cfg["hair_rough"])
    feather = make_material(key + "_feather", cfg["feather"], 0.05, 0.55,
                            emission=cfg["feather_em"], emission_strength=0.5 if cfg["feather_em"] else 0.0)
    steel = make_material(key + "_steel", cfg["steel"], 0.95, 0.16)
    eye = make_material(key + "_eye", (0.10, 0.12, 0.20), 0.1, 0.3)

    parts = []

    def P(obj, bone):
        bind(obj, arm, bone)
        parts.append(obj)
        return obj

    # ---- торс: закрытый крой, акцент — тонкая талия и нагрудник
    bk = cfg.get("bulk", 1.0)
    P(sphere(key + "_chestplate", 0.185 * bk, (0, -0.012, 1.34), mat=armor, coll=coll, sx=1.06, sy=0.82, sz=1.0), "Chest")
    P(sphere(key + "_bustL", 0.075, (0.062, -0.10, 1.375), mat=armor, coll=coll, sx=1.0, sy=0.75, sz=0.9), "Chest")
    P(sphere(key + "_bustR", 0.075, (-0.062, -0.10, 1.375), mat=armor, coll=coll, sx=1.0, sy=0.75, sz=0.9), "Chest")
    P(torus(key + "_collar", 0.115, 0.022, (0, 0, 1.455), mat=trim, coll=coll), "Chest")
    P(cyl(key + "_abdomen", 0.115 * bk, 0.135 * bk, 0.22, (0, 0, 1.185), mat=suit, coll=coll), "Spine")
    P(torus(key + "_belt", 0.135, 0.028, (0, 0, 1.075), mat=trim, coll=coll), "Hips")
    P(cyl(key + "_pelvis", 0.15, 0.135, 0.16, (0, 0, 0.985), mat=suit, coll=coll), "Hips")
    # юбка-фолд: закрытая, до середины бедра, с золотой каймой
    P(cyl(key + "_fauld", 0.185, 0.245, 0.30, (0, 0, 0.80), mat=armor, coll=coll, seg=14), "Hips")
    P(torus(key + "_fauld_trim", 0.245, 0.016, (0, 0, 0.655), mat=trim, coll=coll), "Hips")
    P(box(key + "_fauld_front", 0.12, 0.02, 0.26, (0, -0.20, 0.78), rot=(6, 0, 0), mat=trim, coll=coll, taper=0.8), "Hips")

    # ---- голова/лицо/волосы
    P(sphere(key + "_head", 0.105, (0, 0, 1.565), mat=skin, coll=coll, sx=0.92, sy=0.95, sz=1.06), "Head")
    P(sphere(key + "_eyeL", 0.016, (0.042, -0.088, 1.585), mat=eye, coll=coll, sx=0.8, sy=0.5, sz=1.0), "Head")
    P(sphere(key + "_eyeR", 0.016, (-0.042, -0.088, 1.585), mat=eye, coll=coll, sx=0.8, sy=0.5, sz=1.0), "Head")
    P(sphere(key + "_haircap", 0.115, (0, 0.012, 1.60), mat=hair, coll=coll, sx=1.0, sy=1.02, sz=0.92), "Head")
    P(box(key + "_hairback", 0.17, 0.075, 0.52, (0, 0.085, 1.36), rot=(7, 0, 0), mat=hair, coll=coll, taper=0.55), "Head")
    P(sphere(key + "_bangL", 0.045, (0.058, -0.082, 1.585), mat=hair, coll=coll, sx=0.55, sy=0.8, sz=1.2), "Head")
    P(sphere(key + "_bangR", 0.045, (-0.058, -0.082, 1.585), mat=hair, coll=coll, sx=0.55, sy=0.8, sz=1.2), "Head")
    if cfg["braids"]:
        P(cyl(key + "_braidL", 0.03, 0.018, 0.34, (0.085, 0.06, 1.36), rot=(12, 0, 14), mat=hair, coll=coll), "Head")
        P(cyl(key + "_braidR", 0.03, 0.018, 0.34, (-0.085, 0.06, 1.36), rot=(12, 0, -14), mat=hair, coll=coll), "Head")
        P(sphere(key + "_ribbonL", 0.028, (0.10, 0.075, 1.50), mat=trim, coll=coll), "Head")
        P(sphere(key + "_ribbonR", 0.028, (-0.10, 0.075, 1.50), mat=trim, coll=coll), "Head")
    if cfg.get("horns", False):
        P(cyl(key + "_hornL", 0.028, 0.006, 0.22, (0.085, 0.02, 1.68), rot=(-20, 0, 35), mat=trim, coll=coll), "Head")
        P(cyl(key + "_hornR", 0.028, 0.006, 0.22, (-0.085, 0.02, 1.68), rot=(-20, 0, -35), mat=trim, coll=coll), "Head")
    if cfg["crown"] == "circlet":
        P(torus(key + "_circlet", 0.10, 0.012, (0, 0, 1.635), mat=trim, coll=coll), "Head")
    elif cfg["crown"] == "crown":
        P(torus(key + "_crownbase", 0.105, 0.016, (0, 0, 1.645), mat=trim, coll=coll), "Head")
        for ang, hgt in [(0, 0.09), (55, 0.065), (-55, 0.065), (115, 0.05), (-115, 0.05)]:
            ax = 0.105 * math.cos(R(ang + 90))
            ay = -0.105 * math.sin(R(ang + 90))
            P(octa(key + "_spike%d" % int(ang + 180), 0.016, 0.5 * hgt,
                   (ax, ay, 1.68 + 0.5 * hgt), rot=(0, ang * 0.2, 0), mat=trim, coll=coll), "Head")

    # ---- руки: плечи-наплечники (золото у II/III), кожа рук, наручи
    for side in ("L", "R"):
        sx = 1 if side == "L" else -1
        pad_scale = (1.0 if cfg["weapon"] == "spear" else 1.12) * bk
        P(sphere(key + "_pauld" + side, 0.085 * pad_scale, (sx * 0.205 * bk, 0, 1.435), mat=armor, coll=coll, sx=1.1, sy=1.0, sz=0.85), "Shoulder." + side)
        P(torus(key + "_pauldrim" + side, 0.075 * pad_scale, 0.014, (sx * 0.205, 0, 1.40), mat=trim, coll=coll), "Shoulder." + side)
        P(sphere(key + "_upperarm" + side, 0.052 * bk, (sx * 0.205, 0.005, 1.27), mat=skin, coll=coll, sx=1.0, sy=1.0, sz=2.8), "UpperArm." + side)
        P(sphere(key + "_forearm" + side, 0.045 * bk, (sx * 0.22, 0.02, 1.02), mat=skin, coll=coll, sx=1.0, sy=1.0, sz=3.0), "LowerArm." + side)
        P(cyl(key + "_vambrace" + side, 0.052, 0.048, 0.14, (sx * 0.222, 0.026, 0.985), mat=armor, coll=coll), "LowerArm." + side)
        P(sphere(key + "_hand" + side, 0.042, (sx * 0.228, 0.035, 0.855), mat=skin, coll=coll, sz=1.2), "Hand." + side)

    # ---- ноги: бёдра (кожа), поножи, сапоги — «акцент на ноги», всё закрыто
    for side in ("L", "R"):
        sx = 1 if side == "L" else -1
        P(sphere(key + "_thigh" + side, 0.062 * bk, (sx * 0.10, 0.005, 0.73), mat=skin, coll=coll, sx=1.0, sy=1.0, sz=2.9), "Thigh." + side)
        P(sphere(key + "_shin" + side, 0.05, (sx * 0.105, 0.015, 0.34), mat=skin, coll=coll, sx=1.0, sy=1.0, sz=3.8), "Shin." + side)
        P(cyl(key + "_greave" + side, 0.058, 0.05, 0.28, (sx * 0.105, -0.005, 0.36), mat=armor, coll=coll), "Shin." + side)
        P(torus(key + "_knee" + side, 0.05, 0.014, (sx * 0.105, 0.0, 0.51), mat=trim, coll=coll), "Shin." + side)
        P(box(key + "_boot" + side, 0.078, 0.135, 0.14, (sx * 0.105, -0.02, 0.11), mat=armor, coll=coll), "Foot." + side)
        P(box(key + "_toecap" + side, 0.072, 0.055, 0.05, (sx * 0.105, -0.11, 0.065), mat=trim, coll=coll), "Foot." + side)

    # ---- крылья: перья-пластины на Wing1/Wing2 (статичная геометрия, простая анимация)
    ws = cfg["wingscale"]
    from mathutils import Vector
    def _bone_box(bname, half_len, w, t, name, m):
        eb_head = Vector([b[2] for b in BONES if b[0] == bname][0])
        eb_tail = Vector([b[3] for b in BONES if b[0] == bname][0])
        mid = (eb_head + eb_tail) * 0.5
        d = (eb_tail - eb_head)
        eul = d.to_track_quat("Z", "Y").to_euler()
        rot = tuple(math.degrees(a) for a in eul)
        return P(box(name, w, t, half_len * 2.0, tuple(mid), rot=rot, mat=m, coll=coll, taper=0.5), bname)
    for side in ("L", "R") if cfg.get("wings", True) else ():
        sx = 1 if side == "L" else -1
        if not cfg.get("wings", True):
            break
        _bone_box("Wing1." + side, 0.19, 0.045, 0.035, key + "_wingarm1" + side, armor)
        _bone_box("Wing2." + side, 0.17, 0.032, 0.026, key + "_wingarm2" + side, armor)
        from mathutils import Vector as _V
        w1h = _V((sx * 0.10, 0.09, 1.40)); w1t = _V((sx * 0.34, 0.30, 1.74))
        w2h = w1t; w2t = _V((sx * 0.62, 0.52, 2.00))
        anchor = [w1h.lerp(w1t, 0.15), w1h.lerp(w1t, 0.5), w1h.lerp(w1t, 0.85),
                  w2h.lerp(w2t, 0.25), w2h.lerp(w2t, 0.6)]
        for i, (bone, ang, ln, wd) in enumerate([
            ("Wing1." + side, 8, 0.40, 0.10),
            ("Wing1." + side, 26, 0.38, 0.09),
            ("Wing1." + side, 44, 0.32, 0.08),
            ("Wing2." + side, 14, 0.38, 0.09),
            ("Wing2." + side, 34, 0.32, 0.075),
        ]):
            fmat = trim if (cfg["wingscale"] > 1.0 and i in (2, 4)) else feather
            base = w1h + (anchor[i] - w1h) * ws
            P(box(key + "_feather_%s_%d" % (side, i), wd * ws, 0.016, ln * ws,
                  tuple(base), rot=(ang * 0.45, sx * ang, 0), mat=fmat, coll=coll, taper=0.28), bone)

    # ---- плащ (форма III)
    if cfg["cape"] is not None:
        cape_m = make_material(key + "_cape", cfg["cape"], 0.05, 0.6)
        P(box(key + "_cape", 0.34, 0.022, 0.86, (0, 0.135, 1.02), rot=(-9, 0, 0), mat=cape_m, coll=coll, taper=1.25), "Chest")
        P(box(key + "_cape_trim", 0.36, 0.018, 0.05, (0, 0.20, 0.60), rot=(-9, 0, 0), mat=trim, coll=coll), "Chest")

    # ---- оружие
    if cfg["weapon"] == "spear":
        P(cyl(key + "_spear_shaft", 0.016, 0.014, 1.75, (-0.235, 0.045, 1.30), mat=steel, coll=coll), "Weapon")
        P(octa(key + "_spear_head", 0.045, 0.16, (-0.235, 0.045, 2.28), mat=trim, coll=coll), "Weapon")
        P(torus(key + "_spear_ring", 0.03, 0.010, (-0.235, 0.045, 2.08), mat=trim, coll=coll), "Weapon")
        P(box(key + "_spear_finL", 0.012, 0.05, 0.16, (-0.27, 0.045, 2.14), rot=(0, 0, 24), mat=steel, coll=coll), "Weapon")
        P(box(key + "_spear_finR", 0.012, 0.05, 0.16, (-0.20, 0.045, 2.14), rot=(0, 0, -24), mat=steel, coll=coll), "Weapon")
    elif cfg["weapon"] == "hammer":
        P(cyl(key + "_ham_shaft", 0.035, 0.03, 1.25, (-0.235, 0.045, 1.15), mat=steel, coll=coll), "Weapon")
        P(box(key + "_ham_head", 0.34, 0.30, 0.42, (-0.235, 0.045, 1.82), mat=steel, coll=coll), "Weapon")
        P(box(key + "_ham_band", 0.36, 0.10, 0.44, (-0.235, 0.045, 1.82), mat=trim, coll=coll), "Weapon")
        P(octa(key + "_ham_spike", 0.05, 0.14, (-0.235, 0.045, 2.10), mat=trim, coll=coll), "Weapon")
        if cfg.get("glow_trim", 0.0) >= 1.0:
            P(octa(key + "_ham_crackL", 0.03, 0.16, (-0.41, 0.045, 1.82), rot=(0, 90, 0), mat=trim, coll=coll), "Weapon")
            P(octa(key + "_ham_crackR", 0.03, 0.16, (-0.06, 0.045, 1.82), rot=(0, 90, 0), mat=trim, coll=coll), "Weapon")
    else:
        for bone, sgn, nm in [("Weapon", -1, "R"), ("Weapon.L", 1, "L")]:
            P(box(key + "_blade_" + nm, 0.030, 0.012, 0.82, (sgn * 0.235, 0.045, 1.24), mat=steel, coll=coll, taper=0.25), bone)
            P(box(key + "_bladeedge_" + nm, 0.034, 0.006, 0.16, (sgn * 0.235, 0.045, 1.70), mat=trim, coll=coll, taper=0.1), bone)
            P(box(key + "_guard_" + nm, 0.13, 0.03, 0.035, (sgn * 0.235, 0.045, 0.845), mat=trim, coll=coll), bone)
            P(cyl(key + "_grip_" + nm, 0.018, 0.016, 0.14, (sgn * 0.233, 0.042, 0.76), mat=suit, coll=coll), bone)

    # ---- аура (форма III): отдельный НЕскинненный узел "Aura" (вращает код visuals)
    if cfg["aura"] is not None:
        aura_m = make_material(key + "_aura", cfg["aura"], 0.0, 0.4,
                               emission=cfg["aura"], emission_strength=2.6, alpha=0.5)
        aura_empty = bpy.data.objects.new("Aura", None)
        aura_empty.empty_display_size = 0.3
        aura_empty.location = (0, 0, 0.045)
        coll.objects.link(aura_empty)
        ring = torus(key + "_auraring", 0.72, 0.045, (0, 0, 0), mat=aura_m, coll=coll, majseg=28, minseg=8)
        ring.parent = aura_empty
        parts.append(ring)
        for i in range(5):
            ang = 2 * math.pi * i / 5.0
            cr = octa(key + "_auracrystal_%d" % i, 0.04, 0.11,
                      (0.62 * math.cos(ang), 0.62 * math.sin(ang), 1.05 + 0.22 * (i % 3)),
                      rot=(0, 0, 14 * i), mat=aura_m, coll=coll)
            cr.parent = aura_empty
            parts.append(cr)
        parts.append(aura_empty)

    # ---- пивот оружия для кода (Empty, экспортируется узлом "WeaponPivot")
    wp = bpy.data.objects.new("WeaponPivot", None)
    wp.empty_display_size = 0.1
    wp.location = (-0.235, 0.045, 0.86)
    coll.objects.link(wp)
    wp.parent = arm
    wp.parent_bone = "Weapon"
    wp.parent_type = "BONE"
    parts.append(wp)

    # ---- анимации (общие тайминги для всех форм)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="POSE")
    for fn in ANIMS:
        fn(arm)
    bpy.ops.object.mode_set(mode="OBJECT")

    # ---- статистика
    tris = 0
    meshes = 0
    for ob in parts:
        if ob.type == "MESH":
            meshes += 1
            tris += sum(len(p.vertices) - 2 for p in ob.data.polygons)
    anim_names = [a.name for a in bpy.data.actions]

    # ---- экспорт .glb (только эта форма)
    for ob in bpy.context.scene.objects:
        ob.select_set(False)
    for ob in parts:
        ob.select_set(True)
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    out = os.path.join(OUT_DIR, cfg.get("out", cfg["file"]))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=out,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_animations=True,
        export_animation_mode="ACTIONS",
        export_skins=True,
        export_normals=True,
        export_materials="EXPORT",
    )
    size = os.path.getsize(out)
    print("[GEN] %s: %s | объектов=%d треугольников=%d анимаций=%d (%s) | %d байт" % (
        key, cfg["label"], meshes, tris, len(anim_names), ",".join(anim_names), size))
    return dict(key=key, file=out, meshes=meshes, tris=tris, anims=anim_names, size=size)


def cleanup_form():
    """Удалить объекты/меши/материалы/экшены текущей формы (формы строятся последовательно)."""
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    for me in list(bpy.data.meshes):
        bpy.data.meshes.remove(me)
    for ma in list(bpy.data.materials):
        bpy.data.materials.remove(ma)
    for ac in list(bpy.data.actions):
        bpy.data.actions.remove(ac)
    for ar in list(bpy.data.armatures):
        bpy.data.armatures.remove(ar)
    for col in list(bpy.data.collections):
        if col.name.startswith("valkyrie"):
            bpy.data.collections.remove(col)


def main():
    bpy.context.scene.render.fps = FPS
    stats = []
    for key in ("valkyrie_f1", "valkyrie_f2", "valkyrie_f3",
                "berserk_f1", "berserk_f2", "berserk_f3"):
        cleanup_form()
        stats.append(build_form(key, FORMS[key]))
    print("[GEN] ГОТОВО: %d моделей в %s" % (len(stats), OUT_DIR))
    for s in stats:
        print("[GEN]   %s -> %s (tris=%d, anims=%d)" % (s["key"], s["file"], s["tris"], len(s["anims"])))


main()
