"""Airbus A321neo. 44.51 m, sharklets."""
import _a320
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a321neo"
SPEC = _a320.spec(44.51, neo=True)
PARTS = {"body": lambda: build_airliner(SPEC)}
