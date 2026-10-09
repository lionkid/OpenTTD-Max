"""Linimo (HSST-100L type) low-speed maglev (2005). 13.5 m cars, 2.6 m wide, large windscreen."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "linimo"

SPEC = {'head_length': 14.0,
 'mid_length': 13.5,
 'width': 2.6,
 'roof': 3.45,
 'skirt': 0.3,
 'e_top': 2.6,
 'e_bot': 4.0,
 'maglev': True,
 'nose': {'length': 3.5,
          'top': [(0.0, 2.2), (0.3, 2.9), (0.65, 3.3), (1.0, 3.45)],
          'bottom': [(0.0, 0.8), (0.3, 0.45), (1.0, 0.3)],
          'width': [(0.0, 0.6), (0.3, 0.88), (0.65, 0.98), (1.0, 1.0)]},
 'cab': {'t0': 0.12, 't1': 0.7, 'depth': 1.15},
 'skirt_mat': 'darkgrey',
 'skirt_z': 0.6,
 'window_margin': 1.2,
 'bands': [{'z': (0.6, 1.0), 'mat': 'cc1'}, {'z': (2.95, 3.1), 'mat': 'cc2', 'where': 'body'}],
 'windows': [{'z': (1.35, 2.5), 'pitch': 2.2, 'duty': 0.8}]}

PARTS = train_parts(SPEC, units=4)
