"""N700S Series Shinkansen (2020). 'Dual supreme wing' nose with sharper edges; white with company-colour bands."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "n700s"

SPEC = {'head_length': 27.35,
 'mid_length': 25.0,
 'width': 3.36,
 'roof': 3.6,
 'skirt': 0.38,
 'nose': {'length': 10.7,
          'top': [(0.0, 0.98), (0.18, 1.22), (0.42, 1.9), (0.6, 2.72), (0.78, 3.3), (1.0, 3.6)],
          'bottom': [(0.0, 0.6), (0.2, 0.44), (1.0, 0.38)],
          'width': [(0.0, 0.48), (0.12, 0.8), (0.3, 0.95), (1.0, 1.0)]},
 'cab': {'t0': 0.52, 't1': 0.74, 'depth': 0.5},
 'bands': [{'z': (1.55, 1.82), 'mat': 'cc1'}, {'z': (1.4, 1.48), 'mat': 'cc1', 'where': 'body'}],
 'windows': [{'z': (2.0, 2.55), 'pitch': 1.6, 'duty': 0.74}],
 'roof_mat': 'lightgrey',
 'roof_z': 3.45}

PARTS = train_parts(SPEC, units=8)
