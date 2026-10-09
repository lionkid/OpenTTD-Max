"""Airbus A310-300. 46.66 m, span 43.9 m, wingtip fences."""
import _a300
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a310_300"
SPEC = _a300.spec(46.66, span=43.9, fence=True, engine_d=2.9)
PARTS = {"body": lambda: build_airliner(SPEC)}
