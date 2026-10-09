"""Boeing 787. Fuselage 5.77 x 5.97 m, raked high-aspect wing with visible upward flex, span 60.12 m."""
from airliner import wing_stations


def spec(length):
    plug = length - 56.72
    f = plug * 0.5
    st = wing_stations(span=60.12, root_y=2.9, root_s_le=20.4 + f, root_chord=11.5, tip_chord=0.8, sweep_le=33,
                       kink={"y": 9.5, "chord": 6.3}, t_root=0.14, t_tip=0.08,
                       rake={"y": 26.0, "sweep_le": 48, "chord": 2.5})
    for station, dz in zip(st, (0.0, 0.1, 0.8, 1.6)):
        station["dz"] = dz
    return {
        "length": length, "fus_w": 5.77, "fus_h": 5.97, "belly_clearance": 2.2,
        "nose_len": 8.8, "nose_pow": 1.8, "tail_len": 14.8, "tail_tip": 0.10,
        "cockpit": (0.58, 0.84),
        "wing": {"stations": st, "dihedral": 6.0, "z_root": 3.0},
        "htail": {"stations": [{"y": 1.2, "s_le": 46.0 + plug, "chord": 6.6}, {"y": 9.7, "s_le": 46.0 + plug + 8.5 * 0.78, "chord": 2.0}],
                  "dihedral": 6.0, "z": 5.7},
        "vtail": {"z_base": 7.3, "stations": [{"h": 0.0, "s_le": 42.0 + plug, "chord": 12.0}, {"h": 1.0, "s_le": 44.0 + plug, "chord": 10.0},
                                              {"h": 9.6, "s_le": 51.6 + plug, "chord": 3.4}]},
        "engines": [{"s": 17.0 + f, "y": 9.5, "z": 2.55, "length": 5.6, "d": 3.25}],
        "gear": {"nose_s": 5.0, "main_s": 27.8 + f, "main_y": [4.9], "wheel_r": 0.6, "bogie": 2},
    }
