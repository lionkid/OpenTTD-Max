"""Airbus A350F. 70.8 m, no cabin windows."""
import _a350
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a350f"
SPEC = _a350.spec(70.8, freighter=True, engine_d=3.7, bogie=3)
PARTS = {"body": lambda: build_airliner(SPEC)}
