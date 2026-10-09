"""923 Series Doctor Yellow (2001). 700-series body in yellow with a company-colour stripe."""
from railcar import train_parts

CATEGORY = "trains"
VEHICLE = "doctor_yellow"

SPEC = {'head_length': 27.35,
 'mid_length': 25.0,
 'width': 3.38,
 'roof': 3.65,
 'skirt': 0.38,
 'body': 'yellow',
 'nose': {'top': [(0.0, 1.05), (0.2, 1.25), (0.45, 1.8), (0.62, 2.55), (0.78, 3.25), (1.0, 3.6)],
          'bottom': [(0.0, 0.6), (0.2, 0.42), (1.0, 0.38)],
          'width': [(0.0, 0.5), (0.15, 0.78), (0.4, 0.95), (1.0, 1.0)],
          'length': 9.2},
 'cab': {'t0': 0.55, 't1': 0.76, 'depth': 0.5},
 'bands': [{'z': (1.5, 1.75), 'mat': 'cc1'}],
 'windows': [{'z': (2.0, 2.55), 'pitch': 2.4, 'duty': 0.5}],
 'pantograph': 7.0}

PARTS = train_parts(SPEC, units=8)
