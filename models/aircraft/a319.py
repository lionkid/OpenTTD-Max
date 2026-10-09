"""Airbus A319. 33.84 m."""
import _a320
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a319"
SPEC = _a320.spec(33.84)
PARTS = {"body": lambda: build_airliner(SPEC)}
