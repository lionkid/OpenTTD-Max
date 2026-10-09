"""Boeing 727-200. Length 46.69 m, span 32.92 m, T-tail, three rear-mounted JT8D (centre one with an S-duct
intake in front of the fin)."""
from airliner import build_airliner, wing_stations

CATEGORY = "aircraft"
VEHICLE = "b727_200"
_CZ = 1.5 + 2.1                      # fuselage centreline height
_FIN_BASE, _FIN_H = _CZ + 1.7, 5.4
SPEC = {
    "length": 46.69, "fus_w": 3.76, "fus_h": 4.2, "belly_clearance": 1.5,
    "nose_len": 6.4, "tail_len": 12.5, "tail_tip": 0.22, "tail_up": 0.3,
    "wing": {"stations": wing_stations(span=32.92, root_y=1.9, root_s_le=16.0, root_chord=7.5, tip_chord=1.6, sweep_le=35,
                                       kink={"y": 5.5, "chord": 4.6}, t_root=0.14, t_tip=0.10),
             "dihedral": 3.0, "z_root": 2.05},
    "vtail": {"z_base": _FIN_BASE, "stations": [{"h": 0.0, "s_le": 33.6, "chord": 9.0}, {"h": _FIN_H, "s_le": 39.4, "chord": 3.6}]},
    "htail": {"stations": [{"y": 0.2, "s_le": 39.6, "chord": 3.4}, {"y": 5.45, "s_le": 39.6 + 5.25 * 0.75, "chord": 1.4}],
              "dihedral": -3.0, "z": _FIN_BASE + _FIN_H - 0.15},
    "engines": [{"s": 34.0, "y": 3.05, "z": _CZ + 0.45, "length": 6.2, "d": 1.6, "kind": "lowbypass", "pylon": "fuselage"},
                {"s": 32.4, "y": 0.0, "z": _CZ + 1.45, "length": 13.6, "d": 1.5, "kind": "lowbypass", "pylon": False,
                 "mirror": False}],
    "gear": {"nose_s": 3.6, "main_s": 22.0, "main_y": [2.85], "wheel_r": 0.52, "bogie": 1},
}
PARTS = {"body": lambda: build_airliner(SPEC)}
