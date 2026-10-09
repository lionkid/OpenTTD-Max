"""Small procedural-geometry helpers for proxy models (bpy + bmesh). Units are metres."""
from __future__ import annotations

import math

import bmesh
import bpy
from mathutils import Matrix, Vector


def material(name: str, rgb, roughness: float = 0.5, metallic: float = 0.0) -> bpy.types.Material:
    """Principled material. rgb is linear; MAX_CC1 / MAX_CC2 names mark company-colour materials."""
    mat = bpy.data.materials.get(name)
    if mat:
        return mat
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    return mat


# Standard palette for proxies. Company colour is 0.5 sRGB (~0.21 linear) so the mask shade is mid-range.
MAT_CC1 = lambda: material("MAX_CC1", (0.214, 0.214, 0.214), roughness=0.45)      # noqa: E731
MAT_WHITE = lambda: material("MAX_white", (0.80, 0.80, 0.82), roughness=0.4)       # noqa: E731
MAT_GREY = lambda: material("MAX_grey", (0.30, 0.30, 0.32), roughness=0.5)         # noqa: E731
MAT_DARK = lambda: material("MAX_dark", (0.015, 0.015, 0.02), roughness=0.3)       # noqa: E731
MAT_METAL = lambda: material("MAX_metal", (0.45, 0.45, 0.47), roughness=0.35, metallic=0.6)  # noqa: E731


def _finish(name: str, bm: bmesh.types.BMesh, mat, matrix: Matrix | None = None) -> bpy.types.Object:
    if matrix is not None:
        bm.transform(matrix)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    for p in mesh.polygons:
        p.use_smooth = False
    obj = bpy.data.objects.new(name, mesh)
    obj.data.materials.append(mat)
    return obj


def box(name, x0, x1, y0, y1, z0, z1, mat, bevel: float = 0.0) -> bpy.types.Object:
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    m = Matrix.Translation(((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)) @ Matrix.Diagonal((x1 - x0, y1 - y0, z1 - z0, 1.0))
    obj = _finish(name, bm, mat, m)
    if bevel > 0:
        mod = obj.modifiers.new("bevel", "BEVEL")
        mod.width = bevel
        mod.segments = 4
        mod.limit_method = "ANGLE"
    return obj


def cylinder_x(name, x0, x1, radius, cy, cz, mat, segments=32, scale_z=1.0) -> bpy.types.Object:
    """Cylinder with its axis along X."""
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segments, radius1=radius, radius2=radius, depth=x1 - x0)
    m = (Matrix.Translation(((x0 + x1) / 2, cy, cz)) @ Matrix.Rotation(math.radians(90), 4, "Y")
         @ Matrix.Diagonal((1.0, 1.0, 1.0, 1.0)))
    bm.transform(m)
    if scale_z != 1.0:
        for v in bm.verts:
            v.co.z = cz + (v.co.z - cz) * scale_z
    return _finish(name, bm, mat)


def cone_x(name, x0, x1, r0, r1, cy, cz0, cz1, mat, segments=32, scale_z=1.0) -> bpy.types.Object:
    """Truncated cone along X from (x0, radius r0, height cz0) to (x1, radius r1, height cz1)."""
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segments, radius1=r0, radius2=r1, depth=x1 - x0)
    bm.transform(Matrix.Rotation(math.radians(90), 4, "Y"))      # axis now along +X, centred at 0
    half = (x1 - x0) / 2
    for v in bm.verts:
        t = (v.co.x + half) / (x1 - x0)                          # 0 at x0 end, 1 at x1 end
        v.co.z = v.co.z * scale_z + cz0 + (cz1 - cz0) * t
        v.co.x += (x0 + x1) / 2
        v.co.y += cy
    return _finish(name, bm, mat)


def ellipsoid(name, cx, cy, cz, rx, ry, rz, mat, segments=24) -> bpy.types.Object:
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segments, v_segments=segments // 2, radius=1.0)
    return _finish(name, bm, mat, Matrix.Translation((cx, cy, cz)) @ Matrix.Diagonal((rx, ry, rz, 1.0)))


def prism(name, poly, z0, z1, mat, plane="xy", offset=0.0, dihedral_deg=0.0) -> bpy.types.Object:
    """Extrude a polygon. plane="xy": poly is (x, y) extruded from z0 to z1 (dihedral tilts z with |y|).
    plane="xz": poly is (x, z) extruded along y from z0 to z1 (so z0/z1 are y bounds), at offset ignored."""
    bm = bmesh.new()
    if plane == "xy":
        bottom = [bm.verts.new((x, y, z0 + abs(y) * math.tan(math.radians(dihedral_deg)))) for x, y in poly]
        top = [bm.verts.new((x, y, z1 + abs(y) * math.tan(math.radians(dihedral_deg)))) for x, y in poly]
    else:
        bottom = [bm.verts.new((x, z0, z)) for x, z in poly]
        top = [bm.verts.new((x, z1, z)) for x, z in poly]
    bm.faces.new(bottom)
    bm.faces.new(list(reversed(top)))
    n = len(poly)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((bottom[j], bottom[i], top[i], top[j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return _finish(name, bm, mat)


def mirror_y(poly):
    return [(x, -y) for x, y in poly]
