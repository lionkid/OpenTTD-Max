"""Airbus A300-600F. 54.08 m, wingtip fences, no cabin windows."""
import _a300
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a300_600f"
SPEC = _a300.spec(54.08, fence=True, freighter=True, engine_d=2.9)
PARTS = {"body": lambda: build_airliner(SPEC)}
