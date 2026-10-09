"""Shared Boeing 747 geometry. Variants differ in fuselage plugs, upper-deck length, tips and engines.
All s positions are for the 747-400 and shifted by the forward plug for the 747-8."""
from airliner import wing_stations


def spec(plug_fwd=0.0, plug_aft=0.0, upper_deck_end=31.0, tip="winglet", freighter=False, engine_d=2.9,
         engine_len=6.5, span_extra=0.0):
    f = plug_fwd
    a = plug_fwd + plug_aft
    length = 70.66 + a
    if tip == "raked":
        wing = wing_stations(span=68.4, root_y=3.1, root_s_le=24.5 + f, root_chord=14.8, tip_chord=1.6, sweep_le=40,
                             kink={"y": 12.0, "chord": 9.2}, t_root=0.14, t_tip=0.09,
                             rake={"y": 30.3, "sweep_le": 52, "chord": 4.0})
        wingtip = None
    else:
        wing = wing_stations(span=62.6 + span_extra, root_y=3.1, root_s_le=24.5 + f, root_chord=14.8, tip_chord=4.0,
                             sweep_le=40, kink={"y": 12.0, "chord": 9.2}, t_root=0.14, t_tip=0.09)
        wingtip = {"kind": "winglet", "height": 1.8, "cant": 29, "sweep": 55} if tip == "winglet" else None
    w = {"stations": wing, "dihedral": 7.0, "z_root": 3.6}
    if wingtip:
        w["tip"] = wingtip
    return {
        "length": length, "fus_w": 6.5, "fus_h": 6.9, "belly_clearance": 2.4,
        "nose_len": 10.5, "tail_len": 18.0, "nose_droop": 0.08,
        "hump": {"start": 0.6, "front": 9.5, "end": upper_deck_end + f, "back": 5.5, "height": 2.15},
        "upper_windows": (5.5, upper_deck_end + f - 3.0) if not freighter else (5.5, 9.0),
        "upper_window_below_top": (1.5, 0.95),
        "windows": not freighter,
        "cockpit": (0.40, 0.60), "cockpit_below_top": (1.0, 0.4),
        "wing": w,
        "htail": {"stations": [{"y": 1.4, "s_le": 56.5 + a, "chord": 9.8}, {"y": 11.1, "s_le": 56.5 + a + 9.7 * 0.84, "chord": 3.0}],
                  "dihedral": 7.0, "z": 6.6},
        "vtail": {"z_base": 8.6, "stations": [{"h": 0.0, "s_le": 51.0 + a, "chord": 15.5}, {"h": 1.0, "s_le": 53.4 + a, "chord": 13.0},
                                              {"h": 10.6, "s_le": 63.4 + a, "chord": 4.2}]},
        "engines": [{"s": 27.3 + f, "y": 11.8, "z": 2.75, "length": engine_len, "d": engine_d},
                    {"s": 35.9 + f, "y": 21.0, "z": 3.75, "length": engine_len, "d": engine_d}],
        "gear": {"nose_s": 8.6 + f, "main_s": [33.2 + f, 35.9 + f], "main_y": [6.0, 1.9], "wheel_r": 0.62, "bogie": 2},
    }
