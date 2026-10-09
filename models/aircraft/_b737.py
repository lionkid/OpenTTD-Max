"""Boeing 737 family. Fuselage 3.76 x 4.01 m; positions scale with fuselage plugs relative to the 737-800.

Generations: "200" (JT8D slung under the wing), "classic" (-300/-400, flattened CFM56-3 nacelles),
"ng" (-700/-800/-900ER, blended winglets), "max" (-8/-9, LEAP-1B, split scimitar winglets)."""
from airliner import wing_stations

REF_LEN, REF_WING = 39.47, 14.2


def spec(length, gen, freighter=False):
    d = REF_LEN - length
    s_le = REF_WING - d * 0.55            # about 55 % of every plug goes ahead of the wing
    tail = length - REF_LEN                # aft positions move with the tail
    if gen in ("200", "classic"):
        span = 28.35 if gen == "200" else 28.88
        wing = wing_stations(span=span, root_y=1.7, root_s_le=s_le, root_chord=6.2, tip_chord=1.6, sweep_le=28,
                             kink={"y": 5.4, "chord": 4.3}, t_root=0.15, t_tip=0.10)
        tip = None
    else:
        wing = wing_stations(span=34.3, root_y=1.7, root_s_le=s_le, root_chord=7.0, tip_chord=1.25, sweep_le=28,
                             kink={"y": 5.6, "chord": 4.6}, t_root=0.15, t_tip=0.10)
        tip = ({"kind": "winglet", "height": 2.44, "cant": 18, "sweep": 52} if gen == "ng"
               else {"kind": "scimitar", "height": 2.9, "lower": 1.0})
    w = {"stations": wing, "dihedral": 6.0, "z_root": 2.25 if gen != "200" else 2.05}
    if tip:
        w["tip"] = tip
    wz_eng = w["z_root"] + (4.9 - 1.7) * 0.105
    engines = {
        "200": {"s": s_le + 1.4, "y": 4.3, "z": wz_eng - 0.9, "length": 5.6, "d": 1.45, "kind": "lowbypass", "pylon": False},
        "classic": {"s": s_le - 1.9, "y": 4.9, "z": 1.55, "length": 3.9, "d": 2.0, "kind": "flat"},
        "ng": {"s": s_le - 2.2, "y": 4.9, "z": 1.5, "length": 4.3, "d": 2.05},
        "max": {"s": s_le - 2.9, "y": 4.9, "z": 1.62, "length": 4.6, "d": 2.25},
    }[gen]
    return {
        "length": length, "fus_w": 3.76, "fus_h": 4.01, "belly_clearance": 1.45 if gen != "200" else 1.3,
        "nose_len": 6.4, "tail_len": 11.2 if gen != "max" else 11.8, "tail_tip": 0.14 if gen != "max" else 0.09,
        "windows": not freighter,
        "wing": w,
        "htail": {"stations": [{"y": 0.6, "s_le": 32.8 + tail, "chord": 4.0},
                               {"y": 7.17, "s_le": 32.8 + tail + 6.6 * 0.70, "chord": 1.4}],
                  "dihedral": 7.0, "z": 3.85},
        "vtail": {"z_base": 4.9, "stations": [{"h": 0.0, "s_le": 28.6 + tail, "chord": 8.6},
                                              {"h": 0.9, "s_le": 30.9 + tail, "chord": 6.3},
                                              {"h": 7.4, "s_le": 36.0 + tail, "chord": 2.1}]},
        "engines": [engines],
        "gear": {"nose_s": 4.6, "main_s": s_le + 6.0, "main_y": [2.86], "wheel_r": 0.56 if gen != "200" else 0.5,
                 "bogie": 1},
    }
