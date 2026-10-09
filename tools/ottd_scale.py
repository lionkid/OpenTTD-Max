"""World scale shared by the renderer and the placeholder generator.

An 8/8-length train vehicle advances 8 world units per car, which is 8 / (16 * sqrt(2)) of a
64 px tile diagonal = 22.6 px at 1x in the E/W view. A 25 m Shinkansen car therefore maps to
about 0.905 px per metre at 1x. Aircraft use the same scale so they stay proportional to trains
and to the stock airport footprints. Calibrated against the base set in M1.
"""
PX_PER_M_1X = 0.905
Z_SCALE = 1.0            # vertical exaggeration applied to models; tune in M1 against base-set sprites
CAMERA_ELEVATION_DEG = 30.0  # gives the 2:1 dimetric projection of a 64x32 tile
