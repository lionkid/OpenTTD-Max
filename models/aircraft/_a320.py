"""Airbus A320 family. Fuselage 3.95 x 4.14 m. Positions for the A320 (37.57 m) shift with plugs.
ceo: wingtip fences, V2500 / CFM56-5; neo: sharklets, larger LEAP-1A / PW1100G nacelles."""
from airliner import wing_stations


def spec(length, neo=False, tall_fin=False):
    plug = length - 37.57
    f = plug * 0.52
    w = {"stations": wing_stations(span=33.9, root_y=1.9, root_s_le=13.4 + f, root_chord=6.6, tip_chord=1.5, sweep_le=27.5,
                                   kink={"y": 6.3, "chord": 4.3}, t_root=0.15, t_tip=0.10),
         "dihedral": 5.1, "z_root": 2.4,
         "tip": ({"kind": "sharklet", "height": 2.43, "cant": 10, "sweep": 45} if neo
                 else {"kind": "fence", "height": 0.9, "lower": 0.55})}
    fin = 0.8 if tall_fin else 0.0
    return {
        "length": length, "fus_w": 3.95, "fus_h": 4.14, "belly_clearance": 1.65,
        "nose_len": 6.6, "tail_len": 11.6,
        "wing": w,
        "htail": {"stations": [{"y": 0.6, "s_le": 31.0 + plug, "chord": 3.8}, {"y": 6.22, "s_le": 31.0 + plug + 5.6 * 0.68, "chord": 1.3}],
                  "dihedral": 6.0, "z": 4.1},
        "vtail": {"z_base": 5.1, "stations": [{"h": 0.0, "s_le": 27.6 + plug, "chord": 7.6}, {"h": 0.7, "s_le": 29.3 + plug, "chord": 5.9},
                                              {"h": 6.5 + fin, "s_le": 34.6 + plug + fin * 0.8, "chord": 2.1}]},
        "engines": [{"s": 11.3 + f - (0.5 if neo else 0.0), "y": 5.75, "z": 1.85 if neo else 1.8,
                     "length": 5.0 if not neo else 5.3, "d": 2.15 if not neo else 2.45}],
        "gear": {"nose_s": 5.1, "main_s": 17.8 + f, "main_y": [3.8], "wheel_r": 0.57, "bogie": 1},
    }
