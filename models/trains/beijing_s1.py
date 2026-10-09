"""Beijing Metro Line S1 medium-low-speed maglev (2017). 15 m cars, 3 m wide."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "beijing_s1"

SPEC = {'head_length': 15.5,
 'mid_length': 15.0,
 'width': 3.0,
 'roof': 3.7,
 'skirt': 0.3,
 'e_top': 2.8,
 'e_bot': 4.0,
 'maglev': True,
 'nose': {'length': 3.2,
          'top': [(0.0, 2.4), (0.3, 3.1), (0.65, 3.55), (1.0, 3.7)],
          'bottom': [(0.0, 0.8), (0.3, 0.45), (1.0, 0.3)],
          'width': [(0.0, 0.65), (0.3, 0.9), (0.65, 0.98), (1.0, 1.0)]},
 'cab': {'t0': 0.1, 't1': 0.7, 'depth': 1.2},
 'skirt_mat': 'darkgrey',
 'skirt_z': 0.6,
 'window_margin': 1.2,
 'bands': [{'z': (0.6, 1.1), 'mat': 'cc1'}, {'z': (3.1, 3.3), 'mat': 'cc1', 'where': 'body'}],
 'windows': [{'z': (1.4, 2.6), 'pitch': 2.4, 'duty': 0.78}]}

PARTS = train_parts(SPEC, units=5)
