"""Airbus A330-300. 63.66 m, span 60.3 m."""
import _a330
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a330_300"
SPEC = _a330.spec(63.66)
PARTS = {"body": lambda: build_airliner(SPEC)}
