"""Airbus A350-1000. 73.79 m, six-wheel bogies."""
import _a350
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a350_1000"
SPEC = _a350.spec(73.79, engine_d=3.7, bogie=3)
PARTS = {"body": lambda: build_airliner(SPEC)}
