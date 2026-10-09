"""Airbus A330 / A340. Circular fuselage 5.64 m, shared wing (span 60.3 m, winglets).
Positions for the A330-300 (63.66 m). A340: four engines and a centreline gear."""
from airliner import wing_stations


def spec(length, quad=False, freighter=False, neo=False, tall_fin=0.0, span=None, engine_d=3.1, engine_len=6.0,
         engines=None):
    plug = length - 63.66
    f = plug * 0.52
    sp = span or (64.0 if neo else 60.3)
    w = {"stations": wing_stations(span=sp - (2.0 if not neo else 4.0), root_y=2.9, root_s_le=23.4 + f, root_chord=11.0,
                                   tip_chord=1.6, sweep_le=31.5, kink={"y": 9.0, "chord": 7.4}, t_root=0.14, t_tip=0.10),
         "dihedral": 5.6, "z_root": 2.85,
         "tip": ({"kind": "sharklet", "height": 4.4, "cant": 20, "sweep": 50} if neo
                 else {"kind": "winglet", "height": 2.74, "cant": 12, "sweep": 55})}
    if engines is None:
        if quad:
            engines = [{"s": 21.4 + f, "y": 9.9, "z": 2.55, "length": engine_len, "d": engine_d},
                       {"s": 27.4 + f, "y": 17.6, "z": 3.4, "length": engine_len, "d": engine_d}]
        else:
            engines = [{"s": 20.0 + f, "y": 9.4, "z": 2.45, "length": engine_len, "d": engine_d}]
    return {
        "length": length, "fus_w": 5.64, "fus_h": 5.64, "belly_clearance": 2.1,
        "nose_len": 8.5, "tail_len": 17.0, "windows": not freighter,
        "wing": w,
        "htail": {"stations": [{"y": 1.1, "s_le": 51.5 + plug, "chord": 7.4}, {"y": 9.7, "s_le": 51.5 + plug + 8.6 * 0.78, "chord": 2.4}],
                  "dihedral": 6.0, "z": 5.3},
        "vtail": {"z_base": 6.9, "stations": [{"h": 0.0, "s_le": 46.8 + plug, "chord": 12.6}, {"h": 0.9, "s_le": 49.0 + plug, "chord": 10.4},
                                              {"h": 9.4 + tall_fin, "s_le": 57.0 + plug + tall_fin * 0.9, "chord": 3.4}]},
        "engines": engines,
        "gear": {"nose_s": 6.6, "main_s": [32.2 + f, 33.4 + f] if quad else 32.2 + f,
                 "main_y": [5.4, 0.45] if quad else [5.4], "wheel_r": 0.62, "bogie": 2},
    }
