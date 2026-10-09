"""L0 Series SCMaglev. End car 28 m with a 15 m nose, intermediate car 24.3 m, width 2.9 m, height 3.1 m.
Livery: white with a company-colour band along the window line (blue on the real train)."""
from railcar import build_car

CATEGORY = "trains"
VEHICLE = "l0"

SPEC = {
    "head_length": 28.0, "mid_length": 24.3, "width": 2.9, "roof": 3.1, "skirt": 0.25, "e_top": 2.4, "e_bot": 4.5,
    "maglev": True,
    "nose": {
        "length": 15.0,
        "top": [(0.0, 0.8), (0.25, 1.0), (0.48, 1.6), (0.63, 2.45), (0.76, 2.92), (0.88, 3.0), (1.0, 3.1)],
        "bottom": [(0.0, 0.5), (0.3, 0.3), (1.0, 0.25)],
        "width": [(0.0, 0.4), (0.2, 0.7), (0.5, 0.93), (1.0, 1.0)],
    },
    "cab": {"t0": 0.62, "t1": 0.78, "depth": 0.45},
    "skirt_mat": "darkgrey", "skirt_z": 0.55,
    "bands": [{"z": (1.55, 1.85), "mat": "cc1"}, {"z": (0.55, 1.55), "mat": "cc1", "where": "nose", "s": (0.0, 6.0)}],
    "windows": [{"z": (1.95, 2.35), "pitch": 1.4, "duty": 0.5}],
}

PARTS = {
    "head": {"build": lambda: build_car(SPEC, "head"), "length_m": 28.0},
    "mid": {"build": lambda: build_car(SPEC, "mid"), "length_m": 24.3},
}
