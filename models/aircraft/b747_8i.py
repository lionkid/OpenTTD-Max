"""Boeing 747-8 Intercontinental. 76.25 m, span 68.4 m (raked), GEnx-2B."""
import _b747
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b747_8i"
SPEC = _b747.spec(plug_fwd=4.1, plug_aft=1.5, upper_deck_end=35.0, tip='raked', engine_d=3.0, engine_len=6.8)
PARTS = {"body": lambda: build_airliner(SPEC)}
