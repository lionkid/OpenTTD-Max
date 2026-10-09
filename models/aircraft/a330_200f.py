"""Airbus A330-200F. 58.82 m, no cabin windows."""
import _a330
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "a330_200f"
SPEC = _a330.spec(58.82, tall_fin=0.5, freighter=True)
PARTS = {"body": lambda: build_airliner(SPEC)}
