"""E2 Series Shinkansen (1997). White with company-colour 1 upper body and company-colour 2 stripe (blue and pink on the real train)."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "e2"

SPEC = {'head_length': 25.7,
 'mid_length': 25.0,
 'width': 3.38,
 'roof': 3.7,
 'skirt': 0.38,
 'nose': {'length': 9.1,
          'top': [(0.0, 1.2), (0.25, 1.7), (0.5, 2.5), (0.72, 3.2), (1.0, 3.7)],
          'bottom': [(0.0, 0.7), (0.3, 0.45), (1.0, 0.38)],
          'width': [(0.0, 0.35), (0.25, 0.7), (0.55, 0.95), (1.0, 1.0)]},
 'cab': {'t0': 0.55, 't1': 0.78, 'depth': 0.5},
 'bands': [{'z': (2.72, 9.0), 'mat': 'cc1', 'where': 'body'}, {'z': (1.88, 2.0), 'mat': 'cc2'}],
 'windows': [{'z': (2.08, 2.62), 'pitch': 1.6, 'duty': 0.74}]}

PARTS = train_parts(SPEC, units=8)
