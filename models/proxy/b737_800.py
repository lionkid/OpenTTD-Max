"""Boeing 737-800 proxy model (M0 pipeline test). Dimensions in metres, nose along +X.

Length 39.5 m, wingspan 35.8 m (with winglets), fuselage diameter 3.76 m, height 12.5 m.
Company colour: tail fin and cheat line. Replace with a detailed mesh in M1.
"""
from maxlib import (MAT_CC1, MAT_DARK, MAT_GREY, MAT_METAL, MAT_WHITE, box, cone_x, cylinder_x, ellipsoid, mirror_y,
                    prism)

CATEGORY = "aircraft"
VEHICLE = "b737_800"
CANVAS_1X = (160, 120)

FUS_R = 1.88
FUS_Z = 3.4          # fuselage centreline height (gear extended)


def build_body():
    objs = []
    white, cc, dark, metal, grey = MAT_WHITE(), MAT_CC1(), MAT_DARK(), MAT_METAL(), MAT_GREY()

    # Fuselage: cylinder + nose ellipsoid + upswept tail cone.
    objs.append(cylinder_x("fuselage", -14.0, 15.0, FUS_R, 0.0, FUS_Z, white))
    objs.append(ellipsoid("nose", 15.0, 0.0, FUS_Z, 4.75, FUS_R, FUS_R, white))
    objs.append(cone_x("tailcone", -19.75, -14.0, 0.35, FUS_R, 0.0, FUS_Z + 1.1, FUS_Z, white))

    # Wings: swept planform, 6 deg dihedral, low mounted.
    wing = [(2.5, 1.5), (-5.85, 17.9), (-7.35, 17.9), (-4.5, 1.5)]
    objs.append(prism("wing_l", wing, 2.1, 2.45, grey, dihedral_deg=6.0))
    objs.append(prism("wing_r", mirror_y(wing), 2.1, 2.45, grey, dihedral_deg=6.0))
    tip_z = 2.1 + 17.9 * 0.105
    winglet = [(-5.85, tip_z), (-7.35, tip_z), (-7.0, tip_z + 2.4), (-6.3, tip_z + 2.4)]
    objs.append(prism("winglet_l", winglet, 17.8, 17.95, cc, plane="xz"))
    objs.append(prism("winglet_r", winglet, -17.95, -17.8, cc, plane="xz"))

    # Horizontal stabiliser and company-colour fin.
    stab = [(-13.5, 1.2), (-17.5, 7.2), (-18.5, 7.2), (-16.5, 1.2)]
    objs.append(prism("stab_l", stab, 4.0, 4.25, grey, dihedral_deg=7.0))
    objs.append(prism("stab_r", mirror_y(stab), 4.0, 4.25, grey, dihedral_deg=7.0))
    fin = [(-11.5, 4.9), (-18.0, 4.9), (-19.5, 12.3), (-17.3, 12.3)]
    objs.append(prism("fin", fin, -0.15, 0.15, cc, plane="xz"))

    # Engines (CFM56 nacelles) and pylons.
    for side, name in ((1, "eng_l"), (-1, "eng_r")):
        objs.append(cylinder_x(name, -0.6, 3.6, 1.05, side * 5.8, 1.75, metal))
        objs.append(box(name + "_pylon", 0.0, 2.0, side * 5.6, side * 6.0, 1.75, 2.3, grey))

    # Livery: company-colour cheat line and dark window band, cockpit glazing.
    objs.append(box("cheatline", -14.0, 15.0, -1.95, 1.95, FUS_Z - 0.5, FUS_Z - 0.1, cc))
    objs.append(box("windows", -13.0, 13.5, -1.92, 1.92, FUS_Z + 0.45, FUS_Z + 0.8, dark))
    objs.append(box("cockpit", 16.0, 17.8, -1.6, 1.6, FUS_Z + 0.6, FUS_Z + 1.25, dark))
    return objs


PARTS = {"body": build_body}
