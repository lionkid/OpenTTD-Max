"""Boeing 787-10. 68.28 m, span 60.12 m."""
import _b787
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b787_10"
SPEC = _b787.spec(68.28)
PARTS = {"body": lambda: build_airliner(SPEC)}
