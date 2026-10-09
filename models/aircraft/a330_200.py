"""Airbus A330-200. 58.82 m, taller fin."""
import _a330
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a330_200"
SPEC = _a330.spec(58.82, tall_fin=0.5)
PARTS = {"body": lambda: build_airliner(SPEC)}
