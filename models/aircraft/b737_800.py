"""Boeing 737-800. Length 39.47 m, span 35.79 m (blended winglets), fuselage 3.76 x 4.01 m."""
from airliner import build_airliner, wing_stations

CATEGORY = "aircraft"
VEHICLE = "b737_800"

SPEC = {
    "length": 39.47, "fus_w": 3.76, "fus_h": 4.01, "belly_clearance": 1.45,
    "nose_len": 6.4, "tail_len": 11.2,
    "wing": {
        "stations": wing_stations(span=34.3, root_y=1.7, root_s_le=14.2, root_chord=7.0, tip_chord=1.25, sweep_le=28,
                                  kink={"y": 5.6, "chord": 4.6}, t_root=0.15, t_tip=0.10),
        "dihedral": 6.0, "z_root": 2.25, "tip": {"kind": "winglet", "height": 2.44, "cant": 18, "sweep": 52},
    },
    "htail": {"stations": [{"y": 0.6, "s_le": 32.8, "chord": 4.0}, {"y": 7.17, "s_le": 32.8 + 6.6 * 0.70, "chord": 1.4}],
              "dihedral": 7.0, "z": 3.85},
    "vtail": {"z_base": 4.9, "stations": [{"h": 0.0, "s_le": 28.6, "chord": 8.6}, {"h": 0.9, "s_le": 30.9, "chord": 6.3},
                                          {"h": 7.4, "s_le": 36.0, "chord": 2.1}]},
    "engines": [{"s": 12.0, "y": 4.9, "z": 1.5, "length": 4.3, "d": 2.05}],
    "gear": {"nose_s": 4.6, "main_s": 20.2, "main_y": [2.86], "wheel_r": 0.56, "bogie": 1},
}

PARTS = {"body": lambda: build_airliner(SPEC)}
