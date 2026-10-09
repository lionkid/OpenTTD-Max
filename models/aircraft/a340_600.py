"""Airbus A340-600. 75.36 m, span 63.45 m, four Trent 500."""
import _a330
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a340_600"
SPEC = _a330.spec(75.36, quad=True, span=63.45, engine_d=2.9, engine_len=6.0)
PARTS = {"body": lambda: build_airliner(SPEC)}
