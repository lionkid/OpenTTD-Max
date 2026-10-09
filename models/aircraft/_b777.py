"""Boeing 777. Fuselage 6.19 x 6.2 m. Positions are for the 777-200 (63.73 m) and shift with plugs."""
from airliner import wing_stations


def spec(plug_fwd=0.0, plug_aft=0.0, raked=False, freighter=False, engine_d=3.6, engine_len=7.0, span=None,
         root_chord=13.4, bogie=3):
    f, a = plug_fwd, plug_fwd + plug_aft
    if raked:
        sp = span or 64.8
        wing = wing_stations(span=sp, root_y=3.0, root_s_le=21.3 + f, root_chord=root_chord, tip_chord=1.3, sweep_le=33,
                             kink={"y": 11.0, "chord": 8.0}, t_root=0.14, t_tip=0.09,
                             rake={"y": sp / 2 - 4.6, "sweep_le": 50, "chord": 3.4})
    else:
        wing = wing_stations(span=60.93, root_y=3.0, root_s_le=21.3 + f, root_chord=root_chord, tip_chord=2.9,
                             sweep_le=33, kink={"y": 11.0, "chord": 8.0}, t_root=0.14, t_tip=0.09)
    return {
        "length": 63.73 + a, "fus_w": 6.19, "fus_h": 6.2, "belly_clearance": 2.35,
        "nose_len": 9.6, "tail_len": 17.5, "nose_droop": 0.10, "tail_tip": 0.10,
        "cockpit": (0.55, 0.82), "windows": not freighter,
        "wing": {"stations": wing, "dihedral": 6.0, "z_root": 3.3},
        "htail": {"stations": [{"y": 1.3, "s_le": 48.9 + a, "chord": 8.0}, {"y": 10.75, "s_le": 48.9 + a + 9.45 * 0.75, "chord": 2.5}],
                  "dihedral": 6.0, "z": 5.9},
        "vtail": {"z_base": 7.9, "stations": [{"h": 0.0, "s_le": 43.9 + a, "chord": 14.0}, {"h": 1.0, "s_le": 45.9 + a, "chord": 12.0},
                                              {"h": 10.4, "s_le": 54.3 + a, "chord": 4.2}]},
        "engines": [{"s": 18.1 + f, "y": 9.7, "z": 2.75, "length": engine_len, "d": engine_d}],
        "gear": {"nose_s": 6.6, "main_s": 32.9 + f, "main_y": [5.5], "wheel_r": 0.62, "bogie": bogie},
    }
