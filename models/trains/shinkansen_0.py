"""0 Series Shinkansen (1964). End car 25.15 m with the rounded 'bullet' nose, intermediate car 25 m,
width 3.38 m. Livery: ivory with company-colour window band and skirt line (blue on the real train)."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "shinkansen_0"

SPEC = {
    "head_length": 25.15, "mid_length": 25.0, "width": 3.38, "roof": 3.75, "skirt": 0.4, "e_top": 2.8,
    "body": "offwhite",
    "nose": {
        "length": 6.2,
        "top": [(0.0, 1.75), (0.12, 2.25), (0.35, 2.85), (0.6, 3.3), (0.85, 3.65), (1.0, 3.75)],
        "bottom": [(0.0, 1.25), (0.12, 0.8), (0.35, 0.52), (1.0, 0.4)],
        "width": [(0.0, 0.12), (0.12, 0.5), (0.35, 0.8), (0.65, 0.96), (1.0, 1.0)],
    },
    "cab": {"t0": 0.55, "t1": 0.82, "depth": 0.55},
    "bands": [{"z": (1.9, 2.75), "mat": "cc1"}, {"z": (0.42, 0.85), "mat": "cc1"}],
    "windows": [{"z": (2.05, 2.55), "pitch": 1.25, "duty": 0.62}],
    "skirt_mat": "cc1", "skirt_z": 0.42,
    "pantograph": 7.0,
}

PARTS = train_parts(SPEC, units=8)
