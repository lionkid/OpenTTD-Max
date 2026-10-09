"""100 Series Shinkansen (1985). Sharper 'shark' nose; ivory with company-colour window band and thin skirt line."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "shinkansen_100"

SPEC = {'head_length': 26.05,
 'mid_length': 25.0,
 'width': 3.38,
 'roof': 3.85,
 'skirt': 0.4,
 'e_top': 3.0,
 'body': 'offwhite',
 'nose': {'length': 7.0,
          'top': [(0.0, 1.45), (0.15, 1.9), (0.4, 2.7), (0.65, 3.35), (0.9, 3.8), (1.0, 3.85)],
          'bottom': [(0.0, 0.95), (0.15, 0.6), (0.4, 0.45), (1.0, 0.4)],
          'width': [(0.0, 0.2), (0.15, 0.55), (0.45, 0.88), (1.0, 1.0)]},
 'cab': {'t0': 0.55, 't1': 0.82, 'depth': 0.5},
 'bands': [{'z': (2.0, 2.65), 'mat': 'cc1'}, {'z': (1.6, 1.72), 'mat': 'cc1'}],
 'windows': [{'z': (2.08, 2.58), 'pitch': 1.6, 'duty': 0.74}],
 'pantograph': 7.0}

PARTS = train_parts(SPEC, units=8)
