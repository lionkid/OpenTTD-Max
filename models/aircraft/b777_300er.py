"""Boeing 777-300ER. 73.86 m, span 64.8 m (raked), GE90-115B."""
import _b777
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b777_300er"
SPEC = _b777.spec(plug_fwd=5.3, plug_aft=4.83, raked=True, engine_d=3.9, engine_len=7.4)
PARTS = {"body": lambda: build_airliner(SPEC)}
