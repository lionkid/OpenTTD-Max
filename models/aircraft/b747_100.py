"""Boeing 747-100. 70.66 m, span 59.6 m, short upper deck."""
import _b747
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b747_100"
SPEC = _b747.spec(upper_deck_end=24.5, tip=None, span_extra=-3.0, engine_d=2.8)
PARTS = {"body": lambda: build_airliner(SPEC)}
