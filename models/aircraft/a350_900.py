"""Airbus A350-900. 66.8 m, span 64.75 m."""
import _a350
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a350_900"
SPEC = _a350.spec(66.8)
PARTS = {"body": lambda: build_airliner(SPEC)}
