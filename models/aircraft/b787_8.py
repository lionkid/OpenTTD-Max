"""Boeing 787-8. 56.72 m, span 60.12 m."""
import _b787
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b787_8"
SPEC = _b787.spec(56.72)
PARTS = {"body": lambda: build_airliner(SPEC)}
