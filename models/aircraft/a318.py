"""Airbus A318. 31.44 m, taller fin."""
import _a320
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a318"
SPEC = _a320.spec(31.44, tall_fin=True)
PARTS = {"body": lambda: build_airliner(SPEC)}
