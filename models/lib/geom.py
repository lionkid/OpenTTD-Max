"""Geometry primitives for procedural vehicle models (bpy + bmesh). Units are metres.

Conventions: the vehicle faces +X, Y is its left side, Z is up, z = 0 is the ground / rail top.
"""
from __future__ import annotations

import math
from typing import Callable, Sequence

import bmesh
import bpy

Vec = tuple[float, float, float]


# ---------------------------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------------------------
def srgb_to_linear(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def material(name: str, srgb, roughness: float = 0.45, metallic: float = 0.0, emission: float = 0.0) -> bpy.types.Material:
    """Principled material from an sRGB colour (0..1). Names starting with MAX_CC1 / MAX_CC2 are
    company-colour materials (see tools/render.py)."""
    mat = bpy.data.materials.get(name)
    if mat:
        return mat
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    lin = tuple(srgb_to_linear(c) for c in srgb)
    bsdf.inputs["Base Color"].default_value = (*lin, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    if emission > 0:
        bsdf.inputs["Emission Color"].default_value = (*lin, 1.0)
        bsdf.inputs["Emission Strength"].default_value = emission
    return mat


PALETTE = {
    # Company colours render as neutral grey; OpenTTD recolours them through the mask.
    "cc1": lambda: material("MAX_CC1", (0.62, 0.62, 0.62), roughness=0.4),
    "cc2": lambda: material("MAX_CC2", (0.62, 0.62, 0.62), roughness=0.4),
    "white": lambda: material("MAX_white", (0.93, 0.93, 0.94), roughness=0.35),
    "offwhite": lambda: material("MAX_offwhite", (0.88, 0.88, 0.86), roughness=0.4),
    "silver": lambda: material("MAX_silver", (0.72, 0.73, 0.75), roughness=0.35, metallic=0.5),
    "lightgrey": lambda: material("MAX_lightgrey", (0.70, 0.71, 0.73), roughness=0.5),
    "grey": lambda: material("MAX_grey", (0.45, 0.46, 0.48), roughness=0.55),
    "darkgrey": lambda: material("MAX_darkgrey", (0.20, 0.20, 0.22), roughness=0.6),
    "glass": lambda: material("MAX_glass", (0.06, 0.08, 0.12), roughness=0.15),
    "black": lambda: material("MAX_black", (0.03, 0.03, 0.035), roughness=0.5),
    "tyre": lambda: material("MAX_tyre", (0.05, 0.05, 0.05), roughness=0.8),
    "metal": lambda: material("MAX_metal", (0.60, 0.61, 0.63), roughness=0.3, metallic=0.8),
    "yellow": lambda: material("MAX_yellow", (0.96, 0.82, 0.10), roughness=0.4),
    "green": lambda: material("MAX_green", (0.10, 0.45, 0.32), roughness=0.4),
    "light": lambda: material("MAX_light", (1.0, 0.97, 0.85), roughness=0.2, emission=1.5),
}


def mat(key):
    """Material by palette key, or pass a material through."""
    if isinstance(key, bpy.types.Material):
        return key
    return PALETTE[key]()


# ---------------------------------------------------------------------------------------------
# Curves
# ---------------------------------------------------------------------------------------------
def pchip(points: Sequence[tuple[float, float]]) -> Callable[[float], float]:
    """Monotone piecewise-cubic interpolation through (t, v) control points (Fritsch-Carlson)."""
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    n = len(xs)
    if n == 1:
        return lambda t: ys[0]
    h = [xs[i + 1] - xs[i] for i in range(n - 1)]
    d = [(ys[i + 1] - ys[i]) / h[i] for i in range(n - 1)]
    m = [0.0] * n
    m[0], m[-1] = d[0], d[-1]
    for i in range(1, n - 1):
        if d[i - 1] * d[i] <= 0:
            m[i] = 0.0
        else:
            w1, w2 = 2 * h[i] + h[i - 1], h[i] + 2 * h[i - 1]
            m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])

    def f(t: float) -> float:
        if t <= xs[0]:
            return ys[0]
        if t >= xs[-1]:
            return ys[-1]
        i = max(k for k in range(n - 1) if xs[k] <= t)
        u = (t - xs[i]) / h[i]
        h00 = 2 * u ** 3 - 3 * u ** 2 + 1
        h10 = u ** 3 - 2 * u ** 2 + u
        h01 = -2 * u ** 3 + 3 * u ** 2
        h11 = u ** 3 - u ** 2
        return h00 * ys[i] + h10 * h[i] * m[i] + h01 * ys[i + 1] + h11 * h[i] * m[i + 1]

    return f


def smoothstep(e0: float, e1: float, x: float) -> float:
    if e1 == e0:
        return 1.0 if x >= e1 else 0.0
    t = min(max((x - e0) / (e1 - e0), 0.0), 1.0)
    return t * t * (3 - 2 * t)


# ---------------------------------------------------------------------------------------------
# Rings
# ---------------------------------------------------------------------------------------------
def se_ring(x: float, cy: float, cz: float, half_w: float, h_top: float, h_bot: float, n: int,
            e_top: float = 2.0, e_bot: float = 2.0) -> list[Vec]:
    """Closed superellipse ring in the YZ plane at x. Exponent 2 = ellipse, larger = boxier."""
    pts = []
    for j in range(n):
        th = 2 * math.pi * j / n
        c, s = math.cos(th), math.sin(th)
        e = e_top if s >= 0 else e_bot
        y = cy + half_w * math.copysign(abs(c) ** (2 / e), c)
        z = cz + (h_top if s >= 0 else h_bot) * math.copysign(abs(s) ** (2 / e), s)
        pts.append((x, y, z))
    return pts


def airfoil(n_half: int, t: float) -> list[tuple[float, float]]:
    """Closed symmetric NACA-00xx loop as (chord fraction from LE, thickness / chord), TE first."""
    xs = [0.5 * (1 - math.cos(math.pi * i / n_half)) for i in range(n_half + 1)]

    def yt(x):
        return 5 * t * (0.2969 * math.sqrt(x) - 0.1260 * x - 0.3516 * x ** 2 + 0.2843 * x ** 3 - 0.1036 * x ** 4)

    upper = [(x, yt(x)) for x in reversed(xs)]          # TE -> LE
    lower = [(x, -yt(x)) for x in xs[1:-1]]            # LE -> TE (exclusive)
    return upper + lower


# ---------------------------------------------------------------------------------------------
# Mesh builders
# ---------------------------------------------------------------------------------------------
def loft(name: str, rings: Sequence[Sequence[Vec]], materials: Sequence, mat_fn=None, cap_start=True, cap_end=True,
         cap_mats=(0, 0), smooth=True) -> bpy.types.Object:
    """Skin consecutive closed rings (same point count) into a closed mesh.
    mat_fn(i, j, centre) -> material slot index for the quad between rings i..i+1, points j..j+1."""
    bm = bmesh.new()
    verts = [[bm.verts.new(p) for p in ring] for ring in rings]
    n = len(rings[0])
    for i in range(len(rings) - 1):
        for j in range(n):
            j2 = (j + 1) % n
            f = bm.faces.new((verts[i][j], verts[i][j2], verts[i + 1][j2], verts[i + 1][j]))
            if mat_fn is not None:
                c = f.calc_center_median()
                f.material_index = mat_fn(i, j, (c.x, c.y, c.z))
            f.smooth = smooth
    if cap_start:
        f = bm.faces.new(list(reversed(verts[0])))
        f.material_index = cap_mats[0]
        f.smooth = False
    if cap_end:
        f = bm.faces.new(verts[-1])
        f.material_index = cap_mats[1]
        f.smooth = False
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    for m in materials:
        obj.data.materials.append(mat(m))
    return obj


def lifting_surface(name: str, stations: Sequence[dict], material_key, axis: str = "y", mirror: bool = False,
                    n_half: int = 10, mat_fn=None, materials=None) -> list[bpy.types.Object]:
    """Wing / tail surface lofted through airfoil sections.

    Each station: {"span": position along the span axis, "x_le": leading-edge x, "chord": m,
                   "t": thickness ratio, "off": offset along the thickness axis (z for wings, y for fins),
                   "lift": optional offset along z for fins (unused for wings)}.
    axis "y": horizontal surface, thickness along z. axis "z": vertical surface, thickness along y.
    """
    rings = []
    for st in stations:
        ring = []
        for xc, tc in airfoil(n_half, st.get("t", 0.12)):
            x = st["x_le"] - xc * st["chord"]
            th = tc * st["chord"]
            if axis == "y":
                ring.append((x, st["span"], st.get("off", 0.0) + th))
            else:
                ring.append((x, st.get("off", 0.0) + th, st["span"]))
        rings.append(ring)
    mats = materials or [material_key]
    objs = [loft(name, rings, mats, mat_fn=mat_fn)]
    if mirror:
        mrings = [[(x, -y, z) for (x, y, z) in ring] for ring in rings]
        objs.append(loft(name + "_m", mrings, mats, mat_fn=mat_fn))
    return objs


def revolve_x(name: str, profile: Sequence[tuple[float, float]], cy: float, cz: float, materials: Sequence,
              n: int = 28, cap_mats=(0, 0), mat_fn=None) -> bpy.types.Object:
    """Body of revolution around an axis parallel to X through (cy, cz). profile: (x, radius)."""
    rings = [se_ring(x, cy, cz, max(r, 0.01), max(r, 0.01), max(r, 0.01), n) for x, r in profile]
    return loft(name, rings, materials, mat_fn=mat_fn, cap_mats=cap_mats)


def box(name: str, x0, x1, y0, y1, z0, z1, material_key) -> bpy.types.Object:
    rings = [[(x, y0, z0), (x, y1, z0), (x, y1, z1), (x, y0, z1)] for x in (x0, x1)]
    return loft(name, rings, [material_key], smooth=False)


def cylinder_y(name: str, cx, cy, cz, radius, width, material_key, n: int = 16) -> bpy.types.Object:
    """Cylinder with its axis along Y (wheels)."""
    rings = []
    for y in (cy - width / 2, cy + width / 2):
        rings.append([(cx + radius * math.cos(2 * math.pi * j / n), y, cz + radius * math.sin(2 * math.pi * j / n))
                      for j in range(n)])
    return loft(name, rings, [material_key])


def cylinder_z(name: str, cx, cy, z0, z1, radius, material_key, n: int = 10) -> bpy.types.Object:
    """Vertical cylinder (struts)."""
    rings = []
    for z in (z0, z1):
        rings.append([(cx + radius * math.cos(2 * math.pi * j / n), cy + radius * math.sin(2 * math.pi * j / n), z)
                      for j in range(n)])
    return loft(name, rings, [material_key], smooth=False)
