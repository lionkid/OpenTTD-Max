"""Aerospatiale/BAC Concorde. Length 61.66 m, span 25.6 m, ogival delta wing, paired Olympus nacelles."""
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "concorde"

# Ogee leading edge (y, s_le) and a straight trailing edge at s = 55.2; thickness about 3 %.
_LE = [(1.3, 19.5), (2.4, 26.5), (4.0, 32.8), (6.0, 38.3), (8.0, 42.4), (10.0, 45.6), (11.6, 48.4), (12.8, 51.0)]
_TE = {12.8: 53.6, 11.6: 54.6}
WING = [{"y": y, "s_le": s, "chord": _TE.get(y, 55.2) - s, "t": 0.035} for y, s in _LE]

SPEC = {
    "length": 61.66, "fus_w": 2.88, "fus_h": 3.32, "belly_clearance": 3.1,
    "nose_len": 9.5, "nose_pow": 1.35, "nose_droop": 0.06,
    "tail_len": 7.5, "tail_tip": 0.12, "tail_up": 0.2,
    "window_z": (0.12, 0.32), "cockpit": (0.72, 0.92), "cockpit_below_top": (0.7, 0.25),
    "wing": {"stations": WING, "dihedral": 0.0, "z_root": 3.45, "material": "white"},
    "vtail": {"z_base": 6.1, "stations": [{"h": 0.0, "s_le": 46.0, "chord": 14.5}, {"h": 5.9, "s_le": 53.6, "chord": 3.0}],
              "material": "cc1"},
    "engines": [{"s": 42.5, "y": 5.1, "z": 2.55, "length": 15.0, "d": 1.4, "w": 3.0, "kind": "box", "pylon": False,
                 "material": "cc2"}],
    "gear": {"nose_s": 14.0, "main_s": 44.5, "main_y": [3.85], "wheel_r": 0.55, "bogie": 2},
}
PARTS = {"body": lambda: build_airliner(SPEC)}
