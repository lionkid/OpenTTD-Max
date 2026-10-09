#!/usr/bin/env python3
"""Render vehicle models to raw 4x sprites with Blender's Python module (bpy).

    BPY=/opt/bpyvenv/bin/python
    $BPY tools/render.py models/proxy/b737_800.py          # one model
    $BPY tools/render.py --all                              # every models/**/*.py except maxlib
    $BPY tools/render.py ... --samples 16                   # quick preview

A model module defines:
    CATEGORY  = "aircraft" | "trains"
    VEHICLE   = "b737_800"                 -> build/render/<CATEGORY>/<VEHICLE>/<part>/
    CANVAS_1X = (width, height)            optional 1x canvas in px (scaled by the zoom factor)
    PARTS     = {"body": build_body, ...}  each builds objects facing +X, resting on z = 0, in metres
Train parts are dicts instead of bare functions:
    PARTS     = {"head": {"build": fn, "length_m": 27.35, "units": 8}, ...}
so the renderer can squeeze the part to its in-game length (see tools/ottd_scale.py).
Materials whose name starts with MAX_CC1 / MAX_CC2 are company-colour materials: they render as
mid grey and the material-id pass marks them red / green for tools/postprocess.py.

Camera: orthographic, 30 deg elevation, looking along +Y, so screen-up is north and the
projection matches OpenTTD's 2:1 tiles. Views are produced by rotating the model, not the camera,
so the light stays fixed relative to the screen like in the base set.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "models"))
sys.path.insert(0, str(ROOT / "models" / "lib"))
from ottd_scale import (AIRCRAFT_PX_PER_M_1X, CAMERA_ELEVATION_DEG, DIAGONAL_STRETCH,  # noqa: E402
                        TRAIN_CROSS_PX_PER_M_1X, TRAIN_VIEW_X_SHIFT_1X, TRAIN_Y_SHIFT_1X,
                        train_length_scale)

ZOOM = 4
Z_SCALE = 1.0          # vertical exaggeration; OpenGFX calibration found none needed
SUN_DIRECTION = Vector((-0.55, -0.35, 0.76))   # from the scene towards the sun: upper-left, slightly in front
SUN_ENERGY = 3.2
AMBIENT = 0.35


def load_model(path: Path):
    if str(path.parent) not in sys.path:
        sys.path.insert(0, str(path.parent))   # family modules such as models/aircraft/_b747.py
    spec = importlib.util.spec_from_file_location(path.stem, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    for attr in ("CATEGORY", "VEHICLE", "PARTS"):
        if not hasattr(mod, attr):
            raise SystemExit(f"{path}: missing {attr}")
    return mod


def reset_scene() -> bpy.types.Scene:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.use_denoising = False
    scene.render.film_transparent = True
    scene.render.filter_size = 1.0
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0.0
    scene.view_settings.gamma = 1.0
    return scene


def setup_camera(scene, canvas_1x, zoom, px_per_m_1x):
    w, h = canvas_1x[0] * zoom, canvas_1x[1] * zoom
    scene.render.resolution_x, scene.render.resolution_y = w, h
    cam = bpy.data.cameras.new("cam")
    cam.type = "ORTHO"
    cam.sensor_fit = "HORIZONTAL"
    cam.ortho_scale = w / (px_per_m_1x * zoom)   # metres across the full image width
    cam.clip_start, cam.clip_end = 0.1, 1000.0
    obj = bpy.data.objects.new("cam", cam)
    elev = math.radians(CAMERA_ELEVATION_DEG)
    d = 300.0
    obj.location = (0.0, -d * math.cos(elev), d * math.sin(elev))
    obj.rotation_euler = (math.radians(90.0 - CAMERA_ELEVATION_DEG), 0.0, 0.0)
    scene.collection.objects.link(obj)
    scene.camera = obj
    return w, h


def setup_lighting(scene, ambient: float, sun: bool):
    world = bpy.data.worlds.new("world")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (1.0, 1.0, 1.0, 1.0)
    bg.inputs[1].default_value = ambient
    scene.world = world
    if sun:
        light = bpy.data.lights.new("sun", "SUN")
        light.energy = SUN_ENERGY
        light.angle = math.radians(4.0)
        obj = bpy.data.objects.new("sun", light)
        travel = -SUN_DIRECTION.normalized()
        obj.rotation_euler = travel.to_track_quat("-Z", "Y").to_euler()
        scene.collection.objects.link(obj)


def id_material(name: str, rgb) -> bpy.types.Material:
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.clear()
    em = nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (*rgb, 1.0)
    em.inputs["Strength"].default_value = 1.0
    out = nodes.new("ShaderNodeOutputMaterial")
    links.new(em.outputs[0], out.inputs[0])
    return mat


def swap_to_id_materials(objects):
    """Replace every material with a flat emission colour; returns the original assignment."""
    cache = {}
    backup = []
    for obj in objects:
        for slot in obj.material_slots:
            m = slot.material
            backup.append((slot, m))
            key = m.name if m else "__none__"
            if key not in cache:
                if m and m.name.startswith("MAX_CC1"):
                    rgb = (1.0, 0.0, 0.0)
                elif m and m.name.startswith("MAX_CC2"):
                    rgb = (0.0, 1.0, 0.0)
                else:
                    rgb = (0.0, 0.0, 0.0)
                cache[key] = id_material(f"__id_{key}", rgb)
            slot.material = cache[key]
    return backup


def restore_materials(backup):
    for slot, m in backup:
        slot.material = m


def part_spec(mod, part):
    """Normalise a PARTS entry to (build_fn, length_m or None, units)."""
    spec = mod.PARTS[part]
    if callable(spec):
        return spec, None, 8
    return spec["build"], spec.get("length_m"), int(spec.get("units", 8))


def render_part(mod, part: str, out_root: Path, samples: int, views=None) -> Path:
    build, length_m, units = part_spec(mod, part)
    is_train = mod.CATEGORY == "trains"
    if is_train and not length_m:
        raise SystemExit(f"{mod.VEHICLE}/{part}: train parts need length_m")
    px_per_m = TRAIN_CROSS_PX_PER_M_1X if is_train else AIRCRAFT_PX_PER_M_1X
    canvas = getattr(mod, "CANVAS_1X", (96, 72) if is_train else (180, 130))

    out = out_root / mod.CATEGORY / mod.VEHICLE / part
    out.mkdir(parents=True, exist_ok=True)
    scene = reset_scene()
    w, h = setup_camera(scene, canvas, ZOOM, px_per_m)
    setup_lighting(scene, AMBIENT, sun=True)

    # Two-level rig: the inner empty squeezes the model along its own length (trains), the outer
    # one rotates it to each view heading. Lights and camera never move.
    turn = bpy.data.objects.new("turn", None)
    squeeze = bpy.data.objects.new("squeeze", None)
    scene.collection.objects.link(turn)
    scene.collection.objects.link(squeeze)
    squeeze.parent = turn
    objects = build()
    for obj in objects:
        if obj.name not in scene.collection.objects:
            scene.collection.objects.link(obj)
        obj.parent = squeeze
    length_scale = train_length_scale(length_m, units) if is_train else 1.0

    for k in (views if views is not None else range(8)):
        heading = math.radians(90.0 - 45.0 * k)   # N, NE, E, SE, S, SW, W, NW
        turn.rotation_euler = (0.0, 0.0, heading)
        sx = length_scale * (DIAGONAL_STRETCH if (is_train and k % 2 == 0) else 1.0)
        squeeze.scale = (sx, 1.0, Z_SCALE)

        scene.cycles.samples = samples
        scene.world.node_tree.nodes["Background"].inputs[1].default_value = AMBIENT
        scene.render.filepath = str(out / f"view{k}_color.png")
        bpy.ops.render.render(write_still=True)

        backup = swap_to_id_materials(objects)
        scene.cycles.samples = 1
        scene.world.node_tree.nodes["Background"].inputs[1].default_value = 0.0
        scene.render.filepath = str(out / f"view{k}_id.png")
        bpy.ops.render.render(write_still=True)
        restore_materials(backup)
        print(f"  {mod.VEHICLE}/{part}: view {k} done", flush=True)

    y_shift = int(round(TRAIN_Y_SHIFT_1X * ZOOM)) if is_train else 0
    (out / "render.json").write_text(json.dumps({
        "zoom": ZOOM, "anchor": [w // 2, h // 2 - y_shift], "px_per_m_1x": px_per_m,
        "length_scale": length_scale, "units": units if is_train else None,
        "view_x_shift_1x": list(TRAIN_VIEW_X_SHIFT_1X) if is_train else [0] * 8,
        # OpenGFX aircraft are centred on their bounding box in every view (tools/calibrate.py).
        "center_views": not is_train,
        "samples": samples, "blender": bpy.app.version_string,
    }, indent=2) + "\n")
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("models", nargs="*", help="model module paths (models/**/*.py)")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--samples", type=int, default=64)
    ap.add_argument("--out", default=str(ROOT / "build" / "render"))
    ap.add_argument("--parts", nargs="*", help="render only these parts")
    ap.add_argument("--views", nargs="*", type=int, help="render only these views (preview; output is not post-processable)")
    args = ap.parse_args()
    paths = [Path(p) for p in args.models]
    if args.all:
        paths += sorted(p for p in (ROOT / "models").glob("*/*.py")
                        if p.parent.name in ("aircraft", "trains", "calibration") and not p.name.startswith("_"))
    if not paths:
        ap.error("give model paths or --all")
    for p in paths:
        mod = load_model(p.resolve())
        print(f"rendering {mod.CATEGORY}/{mod.VEHICLE} ({len(mod.PARTS)} part(s))", flush=True)
        for part in (args.parts or list(mod.PARTS)):
            out = render_part(mod, part, Path(args.out), args.samples, args.views)
            print(f"wrote {out}", flush=True)


if __name__ == "__main__":
    main()
