"""Boeing 777-200. 63.73 m, span 60.93 m."""
import _b777
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b777_200"
SPEC = _b777.spec(engine_d=3.6)
PARTS = {"body": lambda: build_airliner(SPEC)}
