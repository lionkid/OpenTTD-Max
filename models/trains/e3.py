"""E3 Series mini-shinkansen (1997). 20 m cars, 2.95 m wide; white with a company-colour stripe and grey lower body."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "e3"

SPEC = {'head_length': 22.8,
 'mid_length': 20.0,
 'width': 2.95,
 'roof': 3.65,
 'skirt': 0.42,
 'nose': {'length': 6.0,
          'top': [(0.0, 1.3), (0.3, 2.0), (0.6, 2.9), (1.0, 3.65)],
          'bottom': [(0.0, 0.8), (0.3, 0.5), (1.0, 0.42)],
          'width': [(0.0, 0.35), (0.3, 0.75), (0.6, 0.95), (1.0, 1.0)]},
 'cab': {'t0': 0.5, 't1': 0.8, 'depth': 0.55},
 'bands': [{'z': (0.42, 1.55), 'mat': 'cc2'}, {'z': (1.62, 1.82), 'mat': 'cc1'}],
 'bogie_offset': 3.0,
 'windows': [{'z': (2.0, 2.55), 'pitch': 1.4, 'duty': 0.72}]}

PARTS = train_parts(SPEC, units=6)
