"""E7 Series Shinkansen (2014). Ivory with company-colour roof band (sky blue) and company-colour 2 stripe (copper)."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "e7"

SPEC = {'head_length': 26.05,
 'mid_length': 25.0,
 'width': 3.38,
 'roof': 3.65,
 'skirt': 0.38,
 'body': 'offwhite',
 'nose': {'length': 9.1,
          'top': [(0.0, 1.25), (0.2, 1.6), (0.45, 2.35), (0.7, 3.2), (1.0, 3.65)],
          'bottom': [(0.0, 0.65), (0.25, 0.45), (1.0, 0.38)],
          'width': [(0.0, 0.45), (0.2, 0.78), (0.5, 0.96), (1.0, 1.0)]},
 'cab': {'t0': 0.55, 't1': 0.8, 'depth': 0.55},
 'bands': [{'z': (2.75, 9.0), 'mat': 'cc1'},
           {'z': (1.85, 1.97), 'mat': 'cc2'},
           {'z': (2.0, 2.68), 'mat': 'cc1', 'where': 'body'}],
 'windows': [{'z': (2.08, 2.6), 'pitch': 1.6, 'duty': 0.74}]}

PARTS = train_parts(SPEC, units=8)
