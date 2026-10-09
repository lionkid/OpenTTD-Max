"""Transrapid SMT (Shanghai Maglev). End section 27.2 m, middle section 24.8 m, width 3.7 m.
The body wraps around the guideway; the dark lower part stands for the levitation chassis."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "transrapid_smt"

SPEC = {
    "head_length": 27.2, "mid_length": 24.8, "width": 3.7, "roof": 3.95, "skirt": 0.15, "e_top": 2.6, "e_bot": 5.0,
    "maglev": True,
    "nose": {
        "length": 6.5,
        "top": [(0.0, 1.55), (0.15, 2.2), (0.4, 3.0), (0.7, 3.65), (1.0, 3.95)],
        "bottom": [(0.0, 0.85), (0.2, 0.4), (0.5, 0.2), (1.0, 0.15)],
        "width": [(0.0, 0.25), (0.15, 0.6), (0.4, 0.88), (0.75, 0.99), (1.0, 1.0)],
    },
    "cab": {"t0": 0.42, "t1": 0.82, "depth": 0.85},
    "skirt_mat": "darkgrey", "skirt_z": 0.95,
    "bands": [{"z": (0.95, 1.35), "mat": "cc1"}, {"z": (1.42, 1.55), "mat": "cc2"}],
    "windows": [{"z": (2.0, 2.75), "pitch": 1.4, "duty": 0.82}],
}

PARTS = train_parts(SPEC, units=8)
