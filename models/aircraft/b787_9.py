"""Boeing 787-9. 62.81 m, span 60.12 m."""
import _b787
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b787_9"
SPEC = _b787.spec(62.81)
PARTS = {"body": lambda: build_airliner(SPEC)}
