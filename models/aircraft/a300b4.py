"""Airbus A300B4. 53.61 m, span 44.84 m, CF6-50."""
import _a300
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a300b4"
SPEC = _a300.spec(53.61)
PARTS = {"body": lambda: build_airliner(SPEC)}
