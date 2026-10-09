"""Boeing 767. Semi-widebody fuselage 5.03 x 5.41 m, span 47.57 m."""
from airliner import wing_stations


def spec(length, freighter=False):
    plug = length - 48.51
    f = plug * 0.48
    return {
        "length": length, "fus_w": 5.03, "fus_h": 5.41, "belly_clearance": 2.2,
        "nose_len": 8.5, "tail_len": 14.5, "windows": not freighter,
        "wing": {"stations": wing_stations(span=47.57, root_y=2.4, root_s_le=18.3 + f, root_chord=10.3, tip_chord=2.3,
                                           sweep_le=34, kink={"y": 8.5, "chord": 6.5}, t_root=0.15, t_tip=0.10),
                 "dihedral": 6.0, "z_root": 2.85},
        "htail": {"stations": [{"y": 1.0, "s_le": 39.6 + plug, "chord": 6.0}, {"y": 9.3, "s_le": 39.6 + plug + 8.3 * 0.75, "chord": 1.9}],
                  "dihedral": 7.0, "z": 5.4},
        "vtail": {"z_base": 6.9, "stations": [{"h": 0.0, "s_le": 35.2 + plug, "chord": 11.0}, {"h": 0.9, "s_le": 37.0 + plug, "chord": 9.0},
                                              {"h": 8.8, "s_le": 44.6 + plug, "chord": 2.9}]},
        "engines": [{"s": 15.3 + f, "y": 7.6, "z": 2.45, "length": 5.7, "d": 2.9}],
        "gear": {"nose_s": 6.0, "main_s": 25.7 + f, "main_y": [4.65], "wheel_r": 0.6, "bogie": 2},
    }
