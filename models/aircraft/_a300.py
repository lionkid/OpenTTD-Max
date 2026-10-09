"""Airbus A300 / A310. Circular fuselage 5.64 m. Positions for the A300B4 (53.61 m)."""
from airliner import wing_stations


def spec(length, span=44.84, fence=False, freighter=False, engine_d=2.75):
    plug = length - 53.61
    f = plug * 0.5
    w = {"stations": wing_stations(span=span, root_y=2.9, root_s_le=18.6 + f, root_chord=10.0, tip_chord=1.9, sweep_le=30,
                                   kink={"y": 8.4, "chord": 6.5}, t_root=0.15, t_tip=0.105),
         "dihedral": 5.5, "z_root": 2.65}
    if fence:
        w["tip"] = {"kind": "fence", "height": 0.9, "lower": 0.5}
    return {
        "length": length, "fus_w": 5.64, "fus_h": 5.64, "belly_clearance": 2.0,
        "nose_len": 8.4, "tail_len": 15.5, "windows": not freighter,
        "wing": w,
        "htail": {"stations": [{"y": 1.0, "s_le": 43.4 + plug, "chord": 6.2}, {"y": 8.45, "s_le": 43.4 + plug + 7.4 * 0.72, "chord": 2.1}],
                  "dihedral": 6.0, "z": 5.0},
        "vtail": {"z_base": 6.9, "stations": [{"h": 0.0, "s_le": 39.0 + plug, "chord": 11.0}, {"h": 0.9, "s_le": 41.0 + plug, "chord": 9.0},
                                              {"h": 9.0, "s_le": 48.5 + plug, "chord": 3.1}]},
        "engines": [{"s": 15.0 + f, "y": 7.65, "z": 2.25, "length": 5.6, "d": engine_d}],
        "gear": {"nose_s": 5.8, "main_s": 24.4 + f, "main_y": [4.8], "wheel_r": 0.6, "bogie": 2},
    }
