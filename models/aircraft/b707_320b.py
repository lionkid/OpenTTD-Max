"""Boeing 707-320B. Length 46.61 m, span 44.42 m, four JT3D in long pods."""
from airliner import build_airliner, wing_stations

CATEGORY = "aircraft"
VEHICLE = "b707_320b"
SPEC = {
    "length": 46.61, "fus_w": 3.76, "fus_h": 4.2, "belly_clearance": 1.3,
    "nose_len": 6.5, "tail_len": 11.0,
    "wing": {"stations": wing_stations(span=44.42, root_y=1.9, root_s_le=14.4, root_chord=8.5, tip_chord=2.0, sweep_le=38,
                                       kink={"y": 6.0, "chord": 5.8}, t_root=0.14, t_tip=0.09),
             "dihedral": 7.0, "z_root": 2.1},
    "htail": {"stations": [{"y": 0.7, "s_le": 37.0, "chord": 4.5}, {"y": 6.97, "s_le": 37.0 + 6.27 * 0.78, "chord": 1.6}],
              "dihedral": 7.0, "z": 3.9},
    "vtail": {"z_base": 5.0, "stations": [{"h": 0.0, "s_le": 33.0, "chord": 8.0}, {"h": 0.6, "s_le": 34.5, "chord": 6.5},
                                          {"h": 7.6, "s_le": 40.6, "chord": 2.4}]},
    "engines": [{"s": 15.8, "y": 7.3, "z": 1.75, "length": 6.0, "d": 1.6, "kind": "lowbypass"},
                {"s": 20.5, "y": 13.0, "z": 2.45, "length": 6.0, "d": 1.6, "kind": "lowbypass"}],
    "gear": {"nose_s": 6.0, "main_s": 22.5, "main_y": [3.4], "wheel_r": 0.55, "bogie": 2},
}
PARTS = {"body": lambda: build_airliner(SPEC)}
