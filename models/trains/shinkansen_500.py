"""500 Series Shinkansen (1997). Circular cross-section and a 15 m conical nose with a fighter-style canopy."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "shinkansen_500"

SPEC = {'head_length': 27.0,
 'mid_length': 25.0,
 'width': 3.38,
 'roof': 3.69,
 'skirt': 0.4,
 'e_top': 2.0,
 'e_bot': 2.6,
 'body': 'silver',
 'nose': {'length': 15.0,
          'top': [(0.0, 1.55), (0.3, 2.05), (0.6, 2.75), (0.85, 3.4), (1.0, 3.69)],
          'bottom': [(0.0, 1.15), (0.3, 0.75), (0.6, 0.5), (1.0, 0.4)],
          'width': [(0.0, 0.1), (0.3, 0.5), (0.6, 0.8), (1.0, 1.0)]},
 'cab': {'t0': 0.58, 't1': 0.76, 'depth': 0.42},
 'bands': [{'z': (1.35, 1.52), 'mat': 'cc1'}],
 'windows': [{'z': (2.0, 2.6), 'pitch': 1.6, 'duty': 0.8}],
 'pantograph': 7.0}

PARTS = train_parts(SPEC, units=8)
