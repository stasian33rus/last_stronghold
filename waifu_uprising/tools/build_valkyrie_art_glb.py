#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Конвейер художественной модели Валькирии (Этап 3.4).
Запуск:  blender --background --python tools/build_valkyrie_art_glb.py -- <outdir> [composition]

Собирает ОДНУ базовую игровую модель Валькирии (valkyrie_art_f1.glb) из
легальных CC0-источников (KayKit Character Pack: Adventurers, Kay Lousberg):
  * основа/лицо/волосы  — Rogue (женственная голова, причёска);
  * броня (торс/руки/ноги/плащ) — Knight (латный комплект без шлема);
  * оружие: меч 1H (handslot.r) + круглый щит (handslot.l) — из того же пака;
  * крылья Валькирии — новые стилизованные перьевые крылья (2 кости на крыло,
    имена Wing1/Wing2.L/R как в прежнем риге этапа 3.2);
  * палитра — перекраска атласов в ледяные тона Валькирии (HSV-сдвиг numpy);
  * анимации: 8 контрактных имён (idle/run/attack/skill/parry/hit/death/
    transform) переименованием готовых боевых анимаций пака; root-motion
    (X/Z-трансляция кости root) вырезается — пешку двигает код игры.

Контракт интеграции (scripts/gameplay/player_visuals.gd, tests/smoke_runner.gd):
  AnimationPlayer c 8 анимациями, Skeleton3D >= 20 костей, узел WeaponPivot,
  (Aura — только у формы III), PBR-материалы StandardMaterial3D, рост ~1.7-1.8 м.

Лицензии источников: KayKit — CC0 (без ограничений); итоговый GLB — производная
работа проекта. Никаких API-ключей и внешних генераторов не используется.
"""
import bpy
import bmesh
import math
import os
import sys
import numpy as np
from mathutils import Vector

# ------------------------------------------------------------------ параметры
KAYKIT = os.environ.get(
    "KAYKIT_DIR",
    "/tmp/kaykit_adv/addons/kaykit_character_pack_adventures/Characters/gltf")
OUT_DIR = "/tmp/valkyrie_art"
COMPOSITION = "armor_mix"   # armor_mix | rogue_pure
HEIGHT_TARGET = 1.78        # метры, макушка головы

argv = sys.argv
if "--" in argv:
    args = argv[argv.index("--") + 1:]
    if len(args) >= 1:
        OUT_DIR = args[0]
    if len(args) >= 2:
        COMPOSITION = args[1]
os.makedirs(OUT_DIR, exist_ok=True)

ANIM_MAP = {
    "Idle": "idle",
    "Running_A": "run",
    "1H_Melee_Attack_Slice_Diagonal": "attack",
    "2H_Melee_Attack_Spin": "skill",
    "Block": "parry",
    "Hit_A": "hit",
    "Death_A": "death",
    "Spellcast_Raise": "transform",
}

KEEP_ROGUE = ["Rogue_Head"]
KEEP_ROGUE_FULL = ["Rogue_Head", "Rogue_Body", "Rogue_ArmLeft", "Rogue_ArmRight",
                   "Rogue_LegLeft", "Rogue_LegRight", "Rogue_Cape"]
KEEP_KNIGHT_MIX = ["Knight_Body", "Knight_ArmLeft", "Knight_ArmRight",
                   "Knight_LegLeft", "Knight_LegRight", "Knight_Cape"]
KEEP_KNIGHT_PROPS = ["1H_Sword", "Round_Shield"]


# ------------------------------------------------------------------ утилиты
def log(*a):
    print("[valkyrie-build]", *a)
    sys.stdout.flush()


def rgb_to_hsv(arr):
    r, g, b = arr[..., 0], arr[..., 1], arr[..., 2]
    mx = np.maximum(np.maximum(r, g), b)
    mn = np.minimum(np.minimum(r, g), b)
    d = mx - mn
    h = np.zeros_like(mx)
    m = d > 1e-9
    mr = m & (mx == r)
    mg = m & (mx == g) & ~mr
    mb = m & ~mr & ~mg
    h[mr] = ((g - b)[mr] / d[mr]) % 6.0
    h[mg] = ((b - r)[mg] / d[mg]) + 2.0
    h[mb] = ((r - g)[mb] / d[mb]) + 4.0
    h /= 6.0
    s = np.where(mx > 1e-9, d / np.maximum(mx, 1e-9), 0.0)
    return h, s, mx


def hsv_to_rgb(h, s, v):
    i = np.floor(h * 6.0)
    f = h * 6.0 - i
    p = v * (1 - s)
    q = v * (1 - f * s)
    t = v * (1 - (1 - f) * s)
    i = i.astype(int) % 6
    r = np.choose(i, [v, q, p, p, t, v])
    g = np.choose(i, [t, v, v, q, p, p])
    b = np.choose(i, [p, p, t, v, v, q])
    return np.stack([r, g, b], axis=-1)


def recolor_image(img, shifts):
    """shifts: список (hue_lo, hue_hi, hue_target, sat_mul, val_mul, sat_lo)."""
    w, h = img.size
    buf = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(buf)
    px = buf.reshape(h, w, 4)
    rgb = px[..., :3].copy()
    hh, ss, vv = rgb_to_hsv(rgb)
    for lo, hi, tgt, smul, vmul, sat_lo in shifts:
        if lo <= hi:
            mask = (hh >= lo) & (hh <= hi) & (ss > sat_lo) & (vv > 0.06)
        else:  # переход через 0 (красные тона)
            mask = ((hh >= lo) | (hh <= hi)) & (ss > sat_lo) & (vv > 0.06)
        if not mask.any():
            continue
        nh = hh.copy()
        nh[mask] = tgt
        ns = np.clip(ss * smul, 0, 1)
        nv = np.clip(vv * vmul, 0, 1)
        new_rgb = hsv_to_rgb(nh, ns, nv)
        px[..., :3][mask] = new_rgb[mask]
    img.pixels.foreach_set(px.ravel())
    img.update()
    img.pack()
    log("recolor", img.name, "px", w, h)


def world_bounds(objs):
    mn = Vector((1e9, 1e9, 1e9))
    mx = Vector((-1e9, -1e9, -1e9))
    dg = bpy.context.evaluated_depsgraph_get()
    for ob in objs:
        if ob.type != 'MESH':
            continue
        ev = ob.evaluated_get(dg)
        for c in ev.bound_box:
            w = ev.matrix_world @ Vector(c)
            for i in range(3):
                mn[i] = min(mn[i], w[i])
                mx[i] = max(mx[i], w[i])
    return mn, mx


# ------------------------------------------------------------------ сцена
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

log("import Rogue.glb")
bpy.ops.import_scene.gltf(filepath=os.path.join(KAYKIT, "Rogue.glb"))
rig = next(o for o in scene.objects if o.type == 'ARMATURE')
rogue_meshes = {o.name: o for o in scene.objects if o.type == 'MESH'}

log("import Knight.glb (донор брони/оружия)")
before = set(scene.objects)
bpy.ops.import_scene.gltf(filepath=os.path.join(KAYKIT, "Knight.glb"))
knight_objs = [o for o in scene.objects if o not in before]
rigs = [o for o in scene.objects if o.type == 'ARMATURE']
knight_rig = next(o for o in rigs if o != rig)
knight_meshes = {o.name: o for o in knight_objs if o.type == 'MESH'}

# перескинуть меши-доноры на основной риг (имена костей совпадают)
for name, ob in knight_meshes.items():
    for md in ob.modifiers:
        if md.type == 'ARMATURE':
            md.object = rig
    ob.parent = rig
    ob.matrix_parent_inverse = rig.matrix_world.inverted()

# удалить второй риг и всё неиспользуемое
keep_knight = (KEEP_KNIGHT_MIX + KEEP_KNIGHT_PROPS) if COMPOSITION == "armor_mix" else KEEP_KNIGHT_PROPS
keep_rogue = KEEP_ROGUE if COMPOSITION == "armor_mix" else KEEP_ROGUE_FULL
for ob in list(knight_objs):
    if ob == knight_rig or ob.name in keep_knight:
        continue
    bpy.data.objects.remove(ob, do_unlink=True)
for name, ob in list(rogue_meshes.items()):
    if name not in keep_rogue:
        bpy.data.objects.remove(ob, do_unlink=True)
bpy.data.objects.remove(knight_rig, do_unlink=True)

live = [o for o in scene.objects if o.type == 'MESH']
log("composition", COMPOSITION, "meshes:", sorted(o.name for o in live))

# ------------------------------------------------------------------ перекраска
for img in bpy.data.images:
    n = img.name.lower()
    if "rogue" in n and "texture" in n:
        # зелёная туника -> ледяной синий; рыжие волосы -> платиновый блонд
        recolor_image(img, [
            (0.20, 0.47, 0.58, 1.05, 1.12, 0.12),   # зелень -> синий
            (0.02, 0.115, 0.125, 0.42, 1.55, 0.34), # рыжие волосы -> блонд (кожа мимо: sat ниже)
        ])
    elif "knight" in n and "texture" in n:
        # красные акценты/плащ -> глубокий синий
        recolor_image(img, [
            (0.93, 0.06, 0.60, 1.10, 0.95, 0.12),
            (0.00, 0.05, 0.60, 1.10, 0.95, 0.12),
        ])

# ------------------------------------------------------------------ крылья
def add_wings():
    z_top = world_bounds([o for o in live if "Head" in o.name or "Body" in o.name])[1].z
    z_sh = z_top * 0.46   # плечевая линия хиби-пропорций (голова огромна!)
    wing_mat = bpy.data.materials.new("Valkyrie_Wings")
    wing_mat.use_nodes = True
    bsdf = wing_mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (0.86, 0.93, 1.0, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.45
    try:
        bsdf.inputs["Emission Color"].default_value = (0.55, 0.75, 1.0, 1.0)
        bsdf.inputs["Emission Strength"].default_value = 0.12
    except KeyError:
        pass

    # кости крыльев
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode='EDIT')
    eb = rig.data.edit_bones
    wing_bones = {}
    for side, sx in (("L", 1.0), ("R", -1.0)):
        w1 = eb.new("Wing1." + side)
        w1.head = Vector((sx * 0.06, 0.20, z_sh))
        w1.tail = Vector((sx * 0.26, 0.34, z_sh + 0.12))
        w1.parent = eb.get("chest")
        w1.use_deform = True
        w2 = eb.new("Wing2." + side)
        w2.head = w1.tail.copy()
        w2.tail = Vector((sx * 0.46, 0.52, z_sh - 0.06))
        w2.parent = w1
        w2.use_deform = True
        wing_bones[side] = (w1.name, w2.name)
    bpy.ops.object.mode_set(mode='OBJECT')

    # перья: веер на крыло, один меш на сторону; направления по сфере
    profile = [(-1.0, 0.0), (-0.75, 0.4), (-0.45, 0.8), (0.0, 1.0),
               (0.45, 0.8), (0.75, 0.4), (1.0, 0.0)]
    for side, sx in (("L", 1.0), ("R", -1.0)):
        me = bpy.data.meshes.new("wing_" + side)
        ob = bpy.data.objects.new("wing_" + side, me)
        me.materials.append(wing_mat)
        scene.collection.objects.link(ob)
        bm = bmesh.new()
        groups = {wing_bones[side][0]: [], wing_bones[side][1]: []}
        base = Vector((sx * 0.09, 0.20, z_sh + 0.06))
        for layer, (count, length, wdt0, gname) in enumerate((
                (6, 0.88, 0.180, wing_bones[side][1]),   # маховые (длинные, внахлёст)
                (4, 0.46, 0.160, wing_bones[side][0]))): # кроющие
            lb = base + Vector((sx * 0.01 * layer, -0.015 * layer, 0.035 * layer))
            for i in range(count):
                t = i / max(count - 1, 1)
                el = math.radians(42 - 92 * t)      # полу-сложенные: вверх-назад -> вниз-наружу
                az = math.radians(38 + 30 * t)      # замах назад вдоль спины
                dirv = Vector((sx * math.cos(el) * math.cos(az),
                               math.cos(el) * math.sin(az),
                               math.sin(el)))
                wv = Vector((sx * -math.sin(el) * math.cos(az),
                             -math.sin(el) * math.sin(az),
                             math.cos(el)))
                L = length * (1.0 - 0.28 * t)
                wdt = wdt0 * (1.0 - 0.25 * t)
                idx0 = len(bm.verts)
                for s, l in profile:
                    p = lb + wv * (s * wdt) + dirv * (l * L)
                    p.y += 0.14 * L * l * l          # лёгкая закрутка назад
                    p += dirv.cross(wv).normalized() * (0.008 * i + 0.02 * layer)
                    bm.verts.new(p)
                vs = bm.verts[idx0:idx0 + 7]
                bm.faces.new(vs[:4])
                bm.faces.new(vs[3:7])
                groups[gname] += list(range(idx0, idx0 + 7))
        bm.to_mesh(me)
        bm.free()
        for gname, idxs in groups.items():
            vg = ob.vertex_groups.new(name=gname)
            vg.add(idxs, 1.0, 'REPLACE')
        md = ob.modifiers.new("Armature", 'ARMATURE')
        md.object = rig
        ob.parent = rig


add_wings()

# ------------------------------------------------------------------ анимации
act_data = rig.animation_data
if act_data is None:
    act_data = rig.animation_data_create()
# импортёр glTF кладёт каждый клип в NLA-трек — чистим, иначе экспорт тащит всё
for tr in list(act_data.nla_tracks):
    act_data.nla_tracks.remove(tr)
kept = 0
for act in list(bpy.data.actions):
    if act.name in ANIM_MAP:
        # вырезать root-motion: локация кости root
        for fc in list(act.fcurves):
            if fc.data_path == 'pose.bones["root"].location':
                act.fcurves.remove(fc)
        act.name = ANIM_MAP[act.name]
        act.use_fake_user = True
        kept += 1
    else:
        act.use_fake_user = False
        if act.users == 0:
            bpy.data.actions.remove(act)
log("animations kept:", kept, sorted(a.name for a in bpy.data.actions if a.use_fake_user))

# NLA: каждый контрактный экшен — отдельный трек (экспортёр glTF -> 8 клипов)
for act in bpy.data.actions:
    if act.use_fake_user:
        tr = act_data.nla_tracks.new()
        tr.name = act.name
        st = tr.strips.new(act.name, 0, act)
        st.name = act.name
act_data.action = None  # экспортируются только NLA-треки, без дублей

# ------------------------------------------------------------------ WeaponPivot
wp = bpy.data.objects.new("WeaponPivot", None)
wp.empty_display_size = 0.12
scene.collection.objects.link(wp)
wp.parent = rig
wp.parent_type = 'BONE'
wp.parent_bone = 'handslot.r'

# ------------------------------------------------------------------ масштаб
BODY_HINTS = ("Head", "Body", "Leg", "Arm")
meshes_now = [o for o in scene.objects if o.type == 'MESH']
body_meshes = [o for o in meshes_now if any(hh in o.name for hh in BODY_HINTS)]
mn, mx = world_bounds(body_meshes)
h = mx.z - mn.z
log("native height: %.3f (body only, z %.2f..%.2f)" % (h, mn.z, mx.z))
if abs(h - HEIGHT_TARGET) > 0.02:
    f = HEIGHT_TARGET / h
    rig.scale = (f, f, f)
    bpy.context.view_layer.update()
    log("scale factor: %.4f" % f)

# ------------------------------------------------------------------ экспорт
out_path = os.path.join(OUT_DIR, "valkyrie_art_f1.glb")
bpy.ops.export_scene.gltf(
    filepath=out_path,
    export_format='GLB',
    use_selection=False,
    export_yup=True,
    export_apply=False,
    export_animations=True,
    export_animation_mode='NLA_TRACKS',
    export_skins=True,
    export_materials='EXPORT',
    export_image_format='AUTO',
    export_tangents=True,
    export_normals=True,
)
log("EXPORTED", out_path, os.path.getsize(out_path), "bytes")

# ------------------------------------------------------------------ статистика
tri = 0
dg = bpy.context.evaluated_depsgraph_get()
for ob in meshes_now:
    ev = ob.evaluated_get(dg)
    me = ev.to_mesh()
    me.calc_loop_triangles()
    tri += len(me.loop_triangles)
    ev.to_mesh_clear()
log("TRIANGLES", tri)
log("BONES", len(rig.data.bones))
log("MATERIALS", sorted(m.name for m in bpy.data.materials if m.users))
log("DONE-BUILD")
