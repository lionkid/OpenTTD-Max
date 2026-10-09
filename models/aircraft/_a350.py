"""Airbus A350. Fuselage 5.96 x 6.09 m, curved upturned wingtips, Trent XWB. Positions for the -900 (66.8 m)."""
from airliner import wing_stations


def spec(length, freighter=False, engine_d=3.6, bogie=2):
    plug = length - 66.8
    f = plug * 0.52
    st = wing_stations(span=64.75, root_y=3.0, root_s_le=23.8 + f, root_chord=12.5, tip_chord=0.8, sweep_le=33,
                       kink={"y": 10.0, "chord": 7.0}, t_root=0.14, t_tip=0.08,
                       rake={"y": 28.0, "sweep_le": 55, "chord": 2.6})
    for station, dz in zip(st, (0.0, 0.1, 0.6, 2.4)):
        station["dz"] = dz
    return {
        "length": length, "fus_w": 5.96, "fus_h": 6.09, "belly_clearance": 2.3,
        "nose_len": 9.0, "nose_pow": 1.9, "tail_len": 16.5, "tail_tip": 0.09,
        "cockpit": (0.55, 0.84), "cockpit_below_top": (1.15, 0.3), "windows": not freighter,
        "wing": {"stations": st, "dihedral": 5.5, "z_root": 3.1},
        "htail": {"stations": [{"y": 1.2, "s_le": 54.6 + plug, "chord": 7.2}, {"y": 9.4, "s_le": 54.6 + plug + 8.2 * 0.8, "chord": 2.2}],
                  "dihedral": 6.0, "z": 5.9},
        "vtail": {"z_base": 7.6, "stations": [{"h": 0.0, "s_le": 49.6 + plug, "chord": 13.0}, {"h": 1.0, "s_le": 51.8 + plug, "chord": 10.8},
                                              {"h": 9.4, "s_le": 59.8 + plug, "chord": 3.6}]},
        "engines": [{"s": 20.0 + f, "y": 9.8, "z": 2.65, "length": 6.6, "d": engine_d}],
        "gear": {"nose_s": 6.5, "main_s": 35.1 + f, "main_y": [5.4], "wheel_r": 0.64, "bogie": bogie},
    }
