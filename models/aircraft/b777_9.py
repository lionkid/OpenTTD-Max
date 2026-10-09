"""Boeing 777-9. 76.72 m, span 71.75 m (folding raked tips), GE9X."""
import _b777
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b777_9"
SPEC = _b777.spec(plug_fwd=6.6, plug_aft=6.39, raked=True, span=71.75, engine_d=4.1, engine_len=7.9, root_chord=14.8)
PARTS = {"body": lambda: build_airliner(SPEC)}
