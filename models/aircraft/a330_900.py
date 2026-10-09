"""Airbus A330-900. 63.66 m, span 64.0 m, sharklets, Trent 7000."""
import _a330
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a330_900"
SPEC = _a330.spec(63.66, neo=True, engine_d=3.4, engine_len=6.3)
PARTS = {"body": lambda: build_airliner(SPEC)}
