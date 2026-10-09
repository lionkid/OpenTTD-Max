"""Boeing 757-200. 47.32 m, span 38.05 m."""
import _b757
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b757_200"
SPEC = _b757.spec(47.32)
PARTS = {"body": lambda: build_airliner(SPEC)}
