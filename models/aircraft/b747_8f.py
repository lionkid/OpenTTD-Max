"""Boeing 747-8F. 76.25 m, span 68.4 m (raked), short upper deck, no cabin windows."""
import _b747
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b747_8f"
SPEC = _b747.spec(plug_fwd=4.1, plug_aft=1.5, upper_deck_end=24.5, tip='raked', freighter=True, engine_d=3.0, engine_len=6.8)
PARTS = {"body": lambda: build_airliner(SPEC)}
