"""300 Series Shinkansen (1992). Rounded wedge nose; white with company-colour band under the windows."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "shinkansen_300"

SPEC = {'head_length': 26.05,
 'mid_length': 25.0,
 'width': 3.38,
 'roof': 3.65,
 'skirt': 0.4,
 'nose': {'length': 6.5,
          'top': [(0.0, 1.3), (0.2, 1.75), (0.45, 2.5), (0.7, 3.25), (1.0, 3.65)],
          'bottom': [(0.0, 0.65), (0.25, 0.45), (1.0, 0.4)],
          'width': [(0.0, 0.42), (0.2, 0.75), (0.5, 0.95), (1.0, 1.0)]},
 'cab': {'t0': 0.55, 't1': 0.8, 'depth': 0.5},
 'bands': [{'z': (1.55, 1.85), 'mat': 'cc1'}, {'z': (1.4, 1.47), 'mat': 'cc1', 'where': 'body'}],
 'windows': [{'z': (2.0, 2.55), 'pitch': 1.6, 'duty': 0.74}],
 'pantograph': 7.0,
 'roof_mat': 'lightgrey',
 'roof_z': 3.45}

PARTS = train_parts(SPEC, units=8)
