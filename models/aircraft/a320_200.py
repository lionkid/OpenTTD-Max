"""Airbus A320-200 (ceo). Length 37.57 m, span 34.10 m (wingtip fences), fuselage 3.95 x 4.14 m, V2500."""
from airliner import build_airliner, wing_stations

CATEGORY = "aircraft"
VEHICLE = "a320_200"
SPEC = {
    "length": 37.57, "fus_w": 3.95, "fus_h": 4.14, "belly_clearance": 1.65,
    "nose_len": 6.6, "tail_len": 11.6,
    "wing": {"stations": wing_stations(span=33.9, root_y=1.9, root_s_le=13.4, root_chord=6.6, tip_chord=1.5, sweep_le=27.5,
                                       kink={"y": 6.3, "chord": 4.3}, t_root=0.15, t_tip=0.10),
             "dihedral": 5.1, "z_root": 2.4, "tip": {"kind": "fence", "height": 0.9, "lower": 0.55}},
    "htail": {"stations": [{"y": 0.6, "s_le": 31.0, "chord": 3.8}, {"y": 6.22, "s_le": 31.0 + 5.6 * 0.68, "chord": 1.3}],
              "dihedral": 6.0, "z": 4.1},
    "vtail": {"z_base": 5.1, "stations": [{"h": 0.0, "s_le": 27.6, "chord": 7.6}, {"h": 0.7, "s_le": 29.3, "chord": 5.9},
                                          {"h": 6.5, "s_le": 34.6, "chord": 2.1}]},
    "engines": [{"s": 11.3, "y": 5.75, "z": 1.8, "length": 5.0, "d": 2.15}],
    "gear": {"nose_s": 5.1, "main_s": 17.8, "main_y": [3.8], "wheel_r": 0.57, "bogie": 1},
}
PARTS = {"body": lambda: build_airliner(SPEC)}
