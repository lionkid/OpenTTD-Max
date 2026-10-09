"""CRRC 600 km/h high-speed maglev (2021). Long pointed nose, body wrapping the guideway."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "crrc_600"

SPEC = {'head_length': 27.0,
 'mid_length': 24.8,
 'width': 3.7,
 'roof': 4.0,
 'skirt': 0.15,
 'e_top': 2.5,
 'e_bot': 5.0,
 'maglev': True,
 'nose': {'length': 10.0,
          'top': [(0.0, 1.0), (0.25, 1.5), (0.5, 2.4), (0.72, 3.3), (1.0, 4.0)],
          'bottom': [(0.0, 0.55), (0.3, 0.25), (1.0, 0.15)],
          'width': [(0.0, 0.3), (0.25, 0.68), (0.55, 0.94), (1.0, 1.0)]},
 'cab': {'t0': 0.5, 't1': 0.75, 'depth': 0.6},
 'skirt_mat': 'darkgrey',
 'skirt_z': 0.9,
 'bands': [{'z': (0.9, 1.3), 'mat': 'cc1'}, {'z': (2.9, 3.05), 'mat': 'cc2'}],
 'windows': [{'z': (2.0, 2.75), 'pitch': 1.4, 'duty': 0.82}]}

PARTS = train_parts(SPEC, units=8)
