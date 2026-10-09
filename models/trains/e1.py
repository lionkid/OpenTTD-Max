"""E1 Series Max (1994). Full double-deck, 4.49 m tall; white with company-colour lower body and stripe."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "e1"

SPEC = {'head_length': 26.05,
 'mid_length': 25.0,
 'width': 3.38,
 'roof': 4.485,
 'skirt': 0.38,
 'e_top': 3.4,
 'nose': {'length': 9.4,
          'top': [(0.0, 1.6), (0.25, 2.3), (0.5, 3.3), (0.75, 4.1), (1.0, 4.485)],
          'bottom': [(0.0, 0.75), (0.3, 0.45), (1.0, 0.38)],
          'width': [(0.0, 0.45), (0.25, 0.8), (0.6, 0.97), (1.0, 1.0)]},
 'cab': {'t0': 0.55, 't1': 0.78, 'depth': 0.6},
 'bands': [{'z': (0.38, 1.85), 'mat': 'cc1'}, {'z': (1.95, 2.08), 'mat': 'cc2'}],
 'windows': [{'z': (1.0, 1.55), 'pitch': 1.6, 'duty': 0.74}, {'z': (2.75, 3.35), 'pitch': 1.6, 'duty': 0.74}],
 'pantograph': 7.0}

PARTS = train_parts(SPEC, units=8)
