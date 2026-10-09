"""World scale shared by the renderer, the placeholder generator and the calibration script.

Calibrated in M1 against the OpenGFX base set (tools/calibrate.py, docs/M1-REPORT.md):

Aircraft
    OpenGFX large jets are drawn at roughly true proportions, about 1.0 px per metre at 1x
    (747-class sprite: 68 px long in the E view, 66 px span in the N view).

Trains
    OpenTTD train sprites are "chunky": the cross-section is drawn at about 2.3 px per metre
    (a coach is 8 px wide in the N view and 12 px tall in the E view at 1x), while the length is
    squeezed so that a full-length (8/8) vehicle spans 16 px horizontally in the NE view.
    On top of that, OpenTTD moves vehicles on diagonal track one world unit in x AND y per step,
    so in the N/E/S/W views a vehicle must be sqrt(2) longer than a true projection, otherwise
    gaps open between coupled vehicles. The renderer therefore scales each train part along its
    length to the in-game length and applies the sqrt(2) stretch in the even (N/E/S/W) views.
"""
import math

CAMERA_ELEVATION_DEG = 30.0           # gives the 2:1 dimetric projection of a 64x32 tile

AIRCRAFT_PX_PER_M_1X = 1.0            # uniform scale for aircraft

TRAIN_CROSS_PX_PER_M_1X = 2.3         # width / height of train vehicles
TRAIN_PX_PER_UNIT_1X = 2.0 * math.sqrt(2.0)  # 2.83 px per length unit along a track axis (8/8 = 16 px across in the NE view)
DIAGONAL_STRETCH = math.sqrt(2.0)     # extra length for N/E/S/W views
TRAIN_Y_SHIFT_1X = 2.0                # OpenGFX draws rail vehicles ~2 px lower than the rail-level origin

# Kept for the placeholder generator (true-projection metres for an 8/8 car of 25 m).
PX_PER_M_1X = 0.905


def train_length_scale(length_m: float, units: int) -> float:
    """Factor applied to a train part along its length (model X axis) so that a part of real length
    `length_m` occupies `units` (1..8) in-game length units, relative to the cross-section scale."""
    target_px = units * TRAIN_PX_PER_UNIT_1X
    return target_px / (length_m * TRAIN_CROSS_PX_PER_M_1X)
