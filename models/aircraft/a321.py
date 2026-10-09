"""Airbus A321. 44.51 m."""
import _a320
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a321"
SPEC = _a320.spec(44.51)
PARTS = {"body": lambda: build_airliner(SPEC)}
