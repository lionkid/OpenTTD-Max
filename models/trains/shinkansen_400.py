"""400 Series mini-shinkansen (1992). 20 m cars, 2.95 m wide; silver with a company-colour window band."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "shinkansen_400"

SPEC = {'head_length': 23.0,
 'mid_length': 20.0,
 'width': 2.95,
 'roof': 3.85,
 'skirt': 0.45,
 'body': 'silver',
 'nose': {'length': 4.5,
          'top': [(0.0, 1.6), (0.3, 2.5), (0.6, 3.3), (1.0, 3.85)],
          'bottom': [(0.0, 0.7), (0.3, 0.5), (1.0, 0.45)],
          'width': [(0.0, 0.55), (0.3, 0.85), (0.6, 0.97), (1.0, 1.0)]},
 'cab': {'t0': 0.35, 't1': 0.75, 'depth': 0.6},
 'bands': [{'z': (1.85, 2.75), 'mat': 'cc1'}],
 'bogie_offset': 3.0,
 'windows': [{'z': (2.0, 2.55), 'pitch': 1.4, 'duty': 0.72}],
 'pantograph': 6.0}

PARTS = train_parts(SPEC, units=6)
