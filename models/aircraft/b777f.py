"""Boeing 777F. 63.73 m, span 64.8 m (raked), no cabin windows."""
import _b777
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b777f"
SPEC = _b777.spec(raked=True, freighter=True, engine_d=3.9, engine_len=7.4)
PARTS = {"body": lambda: build_airliner(SPEC)}
