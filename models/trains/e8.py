"""E8 Series mini-shinkansen (2024). Company-colour upper body (purple), white, company-colour 2 stripe (yellow)."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "e8"

SPEC = {'head_length': 23.0,
 'mid_length': 20.0,
 'width': 2.945,
 'roof': 3.65,
 'skirt': 0.4,
 'nose': {'length': 9.0,
          'top': [(0.0, 1.15), (0.25, 1.5), (0.5, 2.3), (0.72, 3.15), (1.0, 3.65)],
          'bottom': [(0.0, 0.65), (0.25, 0.45), (1.0, 0.4)],
          'width': [(0.0, 0.4), (0.2, 0.72), (0.5, 0.95), (1.0, 1.0)]},
 'cab': {'t0': 0.55, 't1': 0.8, 'depth': 0.5},
 'bands': [{'z': (2.7, 9.0), 'mat': 'cc1'}, {'z': (1.85, 1.97), 'mat': 'cc2'}],
 'bogie_offset': 3.0,
 'windows': [{'z': (2.05, 2.6), 'pitch': 1.4, 'duty': 0.72}]}

PARTS = train_parts(SPEC, units=6)
