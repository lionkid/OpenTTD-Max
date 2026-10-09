"""Boeing 747-400F. Short upper deck, winglets, no cabin windows."""
import _b747
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b747_400f"
SPEC = _b747.spec(upper_deck_end=24.5, tip='winglet', freighter=True, engine_d=2.9)
PARTS = {"body": lambda: build_airliner(SPEC)}
