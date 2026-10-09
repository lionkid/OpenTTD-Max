"""Airbus A340-300. 63.69 m, four CFM56-5C, centreline gear."""
import _a330
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a340_300"
SPEC = _a330.spec(63.69, quad=True, engine_d=2.35, engine_len=5.0)
PARTS = {"body": lambda: build_airliner(SPEC)}
