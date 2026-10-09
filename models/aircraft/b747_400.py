"""Boeing 747-400. 70.66 m, span 64.44 m, stretched upper deck, winglets."""
import _b747
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b747_400"
SPEC = _b747.spec(upper_deck_end=31.0, tip='winglet', engine_d=2.9)
PARTS = {"body": lambda: build_airliner(SPEC)}
