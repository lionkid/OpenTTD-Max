"""Airbus A320-200 (ceo). 37.57 m, wingtip fences."""
import _a320
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a320_200"
SPEC = _a320.spec(37.57)
PARTS = {"body": lambda: build_airliner(SPEC)}
