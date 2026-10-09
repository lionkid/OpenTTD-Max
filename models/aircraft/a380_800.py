"""Airbus A380-800. Length 72.72 m, span 79.75 m (wingtip fences), full double-deck fuselage 7.14 x 8.41 m."""
from airliner import build_airliner, wing_stations

CATEGORY = "aircraft"
VEHICLE = "a380_800"
SPEC = {
    "length": 72.72, "fus_w": 7.14, "fus_h": 8.41, "belly_clearance": 2.3,
    "nose_len": 12.0, "tail_len": 18.0, "nose_droop": 0.20, "nose_pow": 2.3,
    "window_z": (-0.08, 0.10), "cheatline_z": (-0.28, -0.14),
    "upper_windows": (9.0, 58.0), "upper_window_below_top": (2.25, 1.65),
    "cockpit": (0.58, 0.80), "cockpit_below_top": (3.6, 2.95),
    "wing": {"stations": wing_stations(span=79.0, root_y=3.4, root_s_le=27.3, root_chord=17.6, tip_chord=4.0, sweep_le=35,
                                       kink={"y": 13.0, "chord": 10.0}, t_root=0.14, t_tip=0.09),
             "dihedral": 5.6, "z_root": 3.9, "tip": {"kind": "fence", "height": 1.6, "lower": 1.0}},
    "htail": {"stations": [{"y": 1.6, "s_le": 58.0, "chord": 11.0}, {"y": 15.2, "s_le": 58.0 + 13.6 * 0.78, "chord": 3.6}],
              "dihedral": 5.0, "z": 7.0},
    "vtail": {"z_base": 10.0, "stations": [{"h": 0.0, "s_le": 52.5, "chord": 17.5}, {"h": 1.2, "s_le": 55.0, "chord": 15.0},
                                           {"h": 14.0, "s_le": 66.0, "chord": 5.2}]},
    "engines": [{"s": 29.0, "y": 12.6, "z": 3.1, "length": 6.6, "d": 3.3},
                {"s": 38.8, "y": 25.7, "z": 4.6, "length": 6.6, "d": 3.3}],
    "gear": {"nose_s": 6.0, "main_s": [39.2, 42.0], "main_y": [6.4, 2.1], "wheel_r": 0.68, "bogie": 2},
}
PARTS = {"body": lambda: build_airliner(SPEC)}
