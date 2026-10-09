"""Airbus A320neo. 37.57 m, sharklets."""
import _a320
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a320neo"
SPEC = _a320.spec(37.57, neo=True)
PARTS = {"body": lambda: build_airliner(SPEC)}
