"""Boeing 757. 737-width fuselage (3.76 x 4.01 m), tall gear, RB211-535 engines. Span 38.05 m."""
from airliner import wing_stations


def spec(length):
    plug = length - 47.32
    f = plug * 0.53
    return {
        "length": length, "fus_w": 3.76, "fus_h": 4.01, "belly_clearance": 1.9,
        "nose_len": 7.0, "tail_len": 12.0, "nose_droop": 0.14,
        "wing": {"stations": wing_stations(span=38.05, root_y=1.75, root_s_le=17.6 + f, root_chord=8.0, tip_chord=1.7,
                                           sweep_le=28, kink={"y": 6.5, "chord": 5.2}, t_root=0.15, t_tip=0.10),
                 "dihedral": 5.0, "z_root": 2.6},
        "htail": {"stations": [{"y": 0.7, "s_le": 39.2 + plug, "chord": 4.6}, {"y": 7.6, "s_le": 39.2 + plug + 6.9 * 0.72, "chord": 1.6}],
                  "dihedral": 7.0, "z": 4.6},
        "vtail": {"z_base": 5.6, "stations": [{"h": 0.0, "s_le": 34.3 + plug, "chord": 10.0}, {"h": 0.9, "s_le": 36.6 + plug, "chord": 7.8},
                                              {"h": 8.0, "s_le": 42.6 + plug, "chord": 2.6}]},
        "engines": [{"s": 15.9 + f, "y": 7.3, "z": 2.05, "length": 5.4, "d": 2.5}],
        "gear": {"nose_s": 4.9, "main_s": 25.8 + f, "main_y": [3.66], "wheel_r": 0.58, "bogie": 2},
    }
