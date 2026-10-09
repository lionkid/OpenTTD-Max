"""E6 Series mini-shinkansen (2013). 13 m nose; company-colour upper body (red on the real train), white lower, company-colour 2 stripe."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "e6"

SPEC = {'head_length': 23.0,
 'mid_length': 20.0,
 'width': 2.945,
 'roof': 3.65,
 'skirt': 0.4,
 'nose': {'length': 13.0,
          'top': [(0.0, 0.95), (0.25, 1.2), (0.45, 1.7), (0.6, 2.5), (0.74, 3.1), (0.86, 3.25), (1.0, 3.65)],
          'bottom': [(0.0, 0.6), (0.25, 0.42), (1.0, 0.4)],
          'width': [(0.0, 0.35), (0.15, 0.6), (0.4, 0.88), (0.7, 0.99), (1.0, 1.0)]},
 'cab': {'t0': 0.6, 't1': 0.78, 'depth': 0.5},
 'bands': [{'z': (2.1, 9.0), 'mat': 'cc1'}, {'z': (1.95, 2.08), 'mat': 'cc2'}],
 'bogie_offset': 3.0,
 'windows': [{'z': (2.15, 2.62), 'pitch': 1.4, 'duty': 0.72}]}

PARTS = train_parts(SPEC, units=6)
