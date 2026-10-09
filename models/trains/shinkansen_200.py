"""200 Series Shinkansen (1982). Bullet nose with a snowplough skirt; cream with company-colour window band and skirt line (green on the real train)."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "shinkansen_200"

SPEC = {'head_length': 25.15,
 'mid_length': 25.0,
 'width': 3.38,
 'roof': 3.85,
 'skirt': 0.4,
 'e_top': 2.8,
 'body': 'offwhite',
 'nose': {'length': 6.5,
          'top': [(0.0, 1.75), (0.12, 2.25), (0.35, 2.9), (0.6, 3.4), (0.85, 3.75), (1.0, 3.85)],
          'bottom': [(0.0, 0.55), (0.15, 0.45), (1.0, 0.4)],
          'width': [(0.0, 0.25), (0.15, 0.55), (0.4, 0.85), (0.7, 0.97), (1.0, 1.0)]},
 'cab': {'t0': 0.55, 't1': 0.82, 'depth': 0.55},
 'bands': [{'z': (1.95, 2.8), 'mat': 'cc1'}, {'z': (0.42, 0.85), 'mat': 'cc1'}],
 'windows': [{'z': (2.1, 2.6), 'pitch': 1.25, 'duty': 0.62}],
 'pantograph': 7.0}

PARTS = train_parts(SPEC, units=8)
