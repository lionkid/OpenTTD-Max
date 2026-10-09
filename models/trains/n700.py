"""N700 Series Shinkansen. End car 27.35 m (10.7 m 'aero double-wing' nose), intermediate car 25 m,
width 3.36 m, height 3.6 m. Livery: white with a company-colour band below the windows and a thin
second band (blue on the real train)."""
from railcar import build_car

CATEGORY = "trains"
VEHICLE = "n700"

SPEC = {
    "head_length": 27.35, "mid_length": 25.0, "width": 3.36, "roof": 3.6, "skirt": 0.38,
    "nose": {
        "length": 10.7,
        "top": [(0.0, 1.05), (0.18, 1.3), (0.42, 1.95), (0.6, 2.75), (0.78, 3.3), (1.0, 3.6)],
        "bottom": [(0.0, 0.62), (0.2, 0.45), (1.0, 0.38)],
        "width": [(0.0, 0.42), (0.15, 0.74), (0.35, 0.93), (0.6, 0.99), (1.0, 1.0)],
    },
    "cab": {"t0": 0.52, "t1": 0.74, "depth": 0.5},
    "bands": [{"z": (1.55, 1.82), "mat": "cc1"}, {"z": (1.4, 1.48), "mat": "cc1", "where": "body"}],
    "windows": [{"z": (2.0, 2.55), "pitch": 1.6, "duty": 0.74}],
    "roof_mat": "lightgrey", "roof_z": 3.45,
}

PARTS = {
    "head": {"build": lambda: build_car(SPEC, "head"), "length_m": 27.35},
    "mid": {"build": lambda: build_car(SPEC, "mid"), "length_m": 25.0},
}
