"""Boeing 777-300ER. Length 73.86 m, span 64.8 m (raked tips), fuselage 6.19 m, GE90-115B."""
from airliner import build_airliner, wing_stations

CATEGORY = "aircraft"
VEHICLE = "b777_300er"
SPEC = {
    "length": 73.86, "fus_w": 6.19, "fus_h": 6.2, "belly_clearance": 2.35,
    "nose_len": 9.6, "tail_len": 17.5, "nose_droop": 0.10, "tail_tip": 0.10,
    "cockpit": (0.55, 0.82),
    "wing": {"stations": wing_stations(span=64.8, root_y=3.0, root_s_le=26.6, root_chord=13.4, tip_chord=1.3,
                                       sweep_le=33, kink={"y": 11.0, "chord": 8.0}, t_root=0.14, t_tip=0.09,
                                       rake={"y": 27.8, "sweep_le": 50, "chord": 3.4}),
             "dihedral": 6.0, "z_root": 3.3},
    "htail": {"stations": [{"y": 1.3, "s_le": 59.0, "chord": 8.0}, {"y": 10.75, "s_le": 59.0 + 9.45 * 0.75, "chord": 2.5}],
              "dihedral": 6.0, "z": 5.9},
    "vtail": {"z_base": 7.9, "stations": [{"h": 0.0, "s_le": 54.0, "chord": 14.0}, {"h": 1.0, "s_le": 56.0, "chord": 12.0},
                                          {"h": 10.4, "s_le": 64.4, "chord": 4.2}]},
    "engines": [{"s": 23.4, "y": 9.7, "z": 2.75, "length": 7.4, "d": 3.9}],
    "gear": {"nose_s": 6.6, "main_s": 38.2, "main_y": [5.5], "wheel_r": 0.62, "bogie": 3},
}
PARTS = {"body": lambda: build_airliner(SPEC)}
