"""N700 Series Shinkansen proxy model (M0 pipeline test). Dimensions in metres, front along +X.

Head car 27.35 m (body 16.65 m + 10.7 m nose), intermediate car 25 m, width 3.36 m, roof 3.6 m.
Company colour: the window-line stripe (blue on the real train).
"""
from maxlib import MAT_CC1, MAT_DARK, MAT_GREY, MAT_WHITE, box, cone_x

CATEGORY = "trains"
VEHICLE = "n700"
CANVAS_1X = (96, 64)

W = 3.36 / 2
FLOOR, ROOF = 0.55, 3.6


def _livery(objs, x0, x1, cc, dark, grey):
    objs.append(box("stripe", x0, x1, -W - 0.02, W + 0.02, 2.05, 2.4, cc))
    objs.append(box("windows", x0 + 1.0, x1 - 1.0, -W - 0.01, W + 0.01, 2.5, 2.9, dark))
    objs.append(box("underframe", x0 + 0.3, x1 - 0.3, -W + 0.35, W - 0.35, 0.35, FLOOR + 0.05, grey))


def build_head():
    objs = []
    white, cc, dark, grey = MAT_WHITE(), MAT_CC1(), MAT_DARK(), MAT_GREY()
    x_rear, x_body = -13.675, 3.0
    objs.append(box("body", x_rear, x_body, -W, W, FLOOR, ROOF, white, bevel=0.45))
    # Nose: tapered from the body section to a low tip 10.7 m ahead.
    objs.append(cone_x("nose", x_body, 13.675, 1.7, 0.3, 0.0, (FLOOR + ROOF) / 2, 1.25, white, scale_z=0.9))
    objs.append(box("cab", x_body + 1.5, x_body + 4.5, -1.3, 1.3, 2.8, 3.25, dark))
    _livery(objs, x_rear, x_body + 3.0, cc, dark, grey)
    return objs


def build_mid():
    objs = []
    white, cc, dark, grey = MAT_WHITE(), MAT_CC1(), MAT_DARK(), MAT_GREY()
    objs.append(box("body", -12.5, 12.5, -W, W, FLOOR, ROOF, white, bevel=0.45))
    _livery(objs, -12.5, 12.5, cc, dark, grey)
    return objs


PARTS = {"head": build_head, "mid": build_mid}
